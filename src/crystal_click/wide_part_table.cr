module CrystalClick
  alias WidePartNumericArray = Array(UInt8) | Array(UInt16) | Array(UInt32) | Array(UInt64) |
                               Array(Int8) | Array(Int16) | Array(Int32) | Array(Int64) | Array(Int128) | Array(UInt128) | Array(Bool) |
                               Array(Float32) | Array(Float64) | Array(UUIDValue) | Array(IPv4Value) | Array(IPv6Value) |
                               Array(Int256Value) | Array(UInt256Value) | Array(Decimal256Value) | Array(BFloat16Value)
  alias WidePartNumericSlice = Slice(UInt8) | Slice(UInt16) | Slice(UInt32) | Slice(UInt64) |
                               Slice(Int8) | Slice(Int16) | Slice(Int32) | Slice(Int64) | Slice(Int128) | Slice(UInt128) | Slice(Bool) |
                               Slice(Float32) | Slice(Float64) | Slice(UUIDValue) | Slice(IPv4Value) | Slice(IPv6Value) |
                               Slice(Int256Value) | Slice(UInt256Value) | Slice(Decimal256Value) | Slice(BFloat16Value)
  alias WidePartNullableArray = Array(UInt8?) | Array(UInt16?) | Array(UInt32?) | Array(UInt64?) |
                                Array(Int8?) | Array(Int16?) | Array(Int32?) | Array(Int64?) | Array(Int128?) | Array(UInt128?) | Array(Bool?) |
                                Array(Float32?) | Array(Float64?) | Array(UUIDValue?) | Array(IPv4Value?) | Array(IPv6Value?) |
                                Array(Int256Value?) | Array(UInt256Value?) | Array(Decimal256Value?) | Array(BFloat16Value?)
  alias WidePartNullableSlice = Slice(UInt8?) | Slice(UInt16?) | Slice(UInt32?) | Slice(UInt64?) |
                                Slice(Int8?) | Slice(Int16?) | Slice(Int32?) | Slice(Int64?) | Slice(Int128?) | Slice(UInt128?) | Slice(Bool?) |
                                Slice(Float32?) | Slice(Float64?) | Slice(UUIDValue?) | Slice(IPv4Value?) | Slice(IPv6Value?) |
                                Slice(Int256Value?) | Slice(UInt256Value?) | Slice(Decimal256Value?) | Slice(BFloat16Value?)
  alias WidePartNullableStringArray = Array(String?)
  alias WidePartNullableStringSlice = Slice(String?)
  alias WidePartArrayNumericArray = Array(Array(UInt8)) | Array(Array(UInt16)) | Array(Array(UInt32)) | Array(Array(UInt64)) |
                                    Array(Array(Int8)) | Array(Array(Int16)) | Array(Array(Int32)) | Array(Array(Int64)) |
                                    Array(Array(Float32)) | Array(Array(Float64)) |
                                    Array(Array(Int128)) | Array(Array(UInt128)) | Array(Array(Int256Value)) | Array(Array(UInt256Value)) |
                                    Array(Array(UUIDValue)) | Array(Array(IPv4Value)) | Array(Array(IPv6Value)) | Array(Array(Decimal256Value)) | Array(Array(BFloat16Value))
  alias WidePartArrayNumericSlice = Slice(Array(UInt8)) | Slice(Array(UInt16)) | Slice(Array(UInt32)) | Slice(Array(UInt64)) |
                                    Slice(Array(Int8)) | Slice(Array(Int16)) | Slice(Array(Int32)) | Slice(Array(Int64)) |
                                    Slice(Array(Float32)) | Slice(Array(Float64)) |
                                    Slice(Array(Int128)) | Slice(Array(UInt128)) | Slice(Array(Int256Value)) | Slice(Array(UInt256Value)) |
                                    Slice(Array(UUIDValue)) | Slice(Array(IPv4Value)) | Slice(Array(IPv6Value)) | Slice(Array(Decimal256Value)) | Slice(Array(BFloat16Value))
  alias WidePartArrayNullableNumericArray = Array(Array(UInt8?)) | Array(Array(UInt16?)) | Array(Array(UInt32?)) | Array(Array(UInt64?)) |
                                            Array(Array(Int8?)) | Array(Array(Int16?)) | Array(Array(Int32?)) | Array(Array(Int64?)) |
                                            Array(Array(Float32?)) | Array(Array(Float64?)) |
                                            Array(Array(Int128?)) | Array(Array(UInt128?)) | Array(Array(Int256Value?)) | Array(Array(UInt256Value?)) |
                                            Array(Array(UUIDValue?)) | Array(Array(IPv4Value?)) | Array(Array(IPv6Value?)) | Array(Array(Decimal256Value?)) | Array(Array(BFloat16Value?))
  alias WidePartArrayNullableNumericSlice = Slice(Array(UInt8?)) | Slice(Array(UInt16?)) | Slice(Array(UInt32?)) | Slice(Array(UInt64?)) |
                                            Slice(Array(Int8?)) | Slice(Array(Int16?)) | Slice(Array(Int32?)) | Slice(Array(Int64?)) |
                                            Slice(Array(Float32?)) | Slice(Array(Float64?)) |
                                            Slice(Array(Int128?)) | Slice(Array(UInt128?)) | Slice(Array(Int256Value?)) | Slice(Array(UInt256Value?)) |
                                            Slice(Array(UUIDValue?)) | Slice(Array(IPv4Value?)) | Slice(Array(IPv6Value?)) | Slice(Array(Decimal256Value?)) | Slice(Array(BFloat16Value?))
  alias WidePartArrayNullableStringArray = Array(Array(String?))
  alias WidePartArrayNullableStringSlice = Slice(Array(String?))
  alias WidePartArrayArrayNullableStringArray = Array(Array(Array(String?)))
  alias WidePartArrayArrayNullableStringSlice = Slice(Array(Array(String?)))
  alias WidePartArrayArrayNumericArray = Array(Array(Array(UInt8))) | Array(Array(Array(UInt16))) | Array(Array(Array(UInt32))) | Array(Array(Array(UInt64))) |
                                         Array(Array(Array(Int8))) | Array(Array(Array(Int16))) | Array(Array(Array(Int32))) | Array(Array(Array(Int64))) |
                                         Array(Array(Array(Float32))) | Array(Array(Array(Float64))) |
                                         Array(Array(Array(Int128))) | Array(Array(Array(UInt128))) |
                                         Array(Array(Array(Int256Value))) | Array(Array(Array(UInt256Value))) | Array(Array(Array(Decimal256Value))) | Array(Array(Array(BFloat16Value)))
  alias WidePartArrayArrayNumericSlice = Slice(Array(Array(UInt8))) | Slice(Array(Array(UInt16))) | Slice(Array(Array(UInt32))) | Slice(Array(Array(UInt64))) |
                                         Slice(Array(Array(Int8))) | Slice(Array(Array(Int16))) | Slice(Array(Array(Int32))) | Slice(Array(Array(Int64))) |
                                         Slice(Array(Array(Float32))) | Slice(Array(Array(Float64))) |
                                         Slice(Array(Array(Int128))) | Slice(Array(Array(UInt128))) |
                                         Slice(Array(Array(Int256Value))) | Slice(Array(Array(UInt256Value))) | Slice(Array(Array(Decimal256Value))) | Slice(Array(Array(BFloat16Value)))
  alias WidePartArrayArrayNullableNumericArray = Array(Array(Array(UInt8?))) | Array(Array(Array(UInt16?))) | Array(Array(Array(UInt32?))) | Array(Array(Array(UInt64?))) |
                                                 Array(Array(Array(Int8?))) | Array(Array(Array(Int16?))) | Array(Array(Array(Int32?))) | Array(Array(Array(Int64?))) |
                                                 Array(Array(Array(Float32?))) | Array(Array(Array(Float64?))) |
                                                 Array(Array(Array(Int128?))) | Array(Array(Array(UInt128?))) |
                                                 Array(Array(Array(Int256Value?))) | Array(Array(Array(UInt256Value?))) | Array(Array(Array(Decimal256Value?))) | Array(Array(Array(BFloat16Value?)))
  alias WidePartArrayArrayNullableNumericSlice = Slice(Array(Array(UInt8?))) | Slice(Array(Array(UInt16?))) | Slice(Array(Array(UInt32?))) | Slice(Array(Array(UInt64?))) |
                                                 Slice(Array(Array(Int8?))) | Slice(Array(Array(Int16?))) | Slice(Array(Array(Int32?))) | Slice(Array(Array(Int64?))) |
                                                 Slice(Array(Array(Float32?))) | Slice(Array(Array(Float64?))) |
                                                 Slice(Array(Array(Int128?))) | Slice(Array(Array(UInt128?))) |
                                                 Slice(Array(Array(Int256Value?))) | Slice(Array(Array(UInt256Value?))) | Slice(Array(Array(Decimal256Value?))) | Slice(Array(Array(BFloat16Value?)))
  alias WidePartArrayBoolArray = Array(Array(Bool))
  alias WidePartArrayBoolSlice = Slice(Array(Bool))
  alias WidePartArrayNullableBoolArray = Array(Array(Bool?))
  alias WidePartArrayNullableBoolSlice = Slice(Array(Bool?))

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
    @array_nullable_uint64_values : Hash(String, Slice(Array(UInt64?)))
    @array_string_values : Hash(String, Slice(Array(String)))
    @array_nullable_string_values : Hash(String, WidePartArrayNullableStringSlice)
    @array_array_uint64_values : Hash(String, Slice(Array(Array(UInt64))))
    @array_array_string_values : Hash(String, Slice(Array(Array(String))))
    @array_array_nullable_string_values : Hash(String, WidePartArrayArrayNullableStringSlice)
    @array_array_nullable_uint64_values : Hash(String, Slice(Array(Array(UInt64?))))
    @array_array_numeric_values : Hash(String, WidePartArrayArrayNumericSlice)
    @array_array_nullable_numeric_values : Hash(String, WidePartArrayArrayNullableNumericSlice)
    @array_numeric_values : Hash(String, WidePartArrayNumericSlice)
    @array_nullable_numeric_values : Hash(String, WidePartArrayNullableNumericSlice)
    @array_bool_values : Hash(String, WidePartArrayBoolSlice)
    @array_nullable_bool_values : Hash(String, WidePartArrayNullableBoolSlice)
    @array_tuple_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64, String))))
    @array_tuple_nullable_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64?, String))))
    @array_tuple_uint64_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64))))
    @variant_string_uint64_values : Hash(String, Slice(VariantStringUInt64Value))
    @variant_bool_string_uint64_values : Hash(String, Slice(VariantBoolStringUInt64Value))
    @tuple_string_values : Hash(String, Slice(Tuple(UInt64, String)))
    @map_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64, String))))
    @map_uint64_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64))))
    @map_string_uint64_values : Hash(String, Slice(Array(Tuple(String, UInt64))))
    @map_string_array_uint64_values : Hash(String, Slice(Array(Tuple(String, Array(UInt64)))))
    @map_string_array_nullable_uint64_values : Hash(String, Slice(Array(Tuple(String, Array(UInt64?)))))
    @map_string_array_nullable_string_values : Hash(String, Slice(Array(Tuple(String, Array(String?)))))
    @map_uint64_array_nullable_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?)))))
    @map_string_string_values : Hash(String, Slice(Array(Tuple(String, String))))
    @map_uint64_nullable_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64?))))
    @map_string_nullable_uint64_values : Hash(String, Slice(Array(Tuple(String, UInt64?))))
    @map_uint64_nullable_string_values : Hash(String, Slice(Array(Tuple(UInt64, String?))))
    @map_string_nullable_string_values : Hash(String, Slice(Array(Tuple(String, String?))))

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
      @array_nullable_uint64_values = Hash(String, Slice(Array(UInt64?))).new
      @array_string_values = Hash(String, Slice(Array(String))).new
      @array_nullable_string_values = Hash(String, WidePartArrayNullableStringSlice).new
      @array_array_uint64_values = Hash(String, Slice(Array(Array(UInt64)))).new
      @array_array_string_values = Hash(String, Slice(Array(Array(String)))).new
      @array_array_nullable_string_values = Hash(String, WidePartArrayArrayNullableStringSlice).new
      @array_array_nullable_uint64_values = Hash(String, Slice(Array(Array(UInt64?)))).new
      @array_array_numeric_values = Hash(String, WidePartArrayArrayNumericSlice).new
      @array_array_nullable_numeric_values = Hash(String, WidePartArrayArrayNullableNumericSlice).new
      @array_numeric_values = Hash(String, WidePartArrayNumericSlice).new
      @array_nullable_numeric_values = Hash(String, WidePartArrayNullableNumericSlice).new
      @array_bool_values = Hash(String, WidePartArrayBoolSlice).new
      @array_nullable_bool_values = Hash(String, WidePartArrayNullableBoolSlice).new
      @array_tuple_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
      @array_tuple_nullable_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64?, String)))).new
      @array_tuple_uint64_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
      @variant_string_uint64_values = Hash(String, Slice(VariantStringUInt64Value)).new
      @variant_bool_string_uint64_values = Hash(String, Slice(VariantBoolStringUInt64Value)).new
      @tuple_string_values = Hash(String, Slice(Tuple(UInt64, String))).new
      @map_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
      @map_uint64_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
      @map_string_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64)))).new
      @map_string_array_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64))))).new
      @map_string_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))).new
      @map_string_array_nullable_string_values = Hash(String, Slice(Array(Tuple(String, Array(String?))))).new
      @map_uint64_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))).new
      @map_string_string_values = Hash(String, Slice(Array(Tuple(String, String)))).new
      @map_uint64_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))).new
      @map_string_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64?)))).new
      @map_uint64_nullable_string_values = Hash(String, Slice(Array(Tuple(UInt64, String?)))).new
      @map_string_nullable_string_values = Hash(String, Slice(Array(Tuple(String, String?)))).new
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
      @array_nullable_uint64_values = Hash(String, Slice(Array(UInt64?))).new
      @array_string_values = Hash(String, Slice(Array(String))).new
      @array_nullable_string_values = Hash(String, WidePartArrayNullableStringSlice).new
      @array_array_uint64_values = Hash(String, Slice(Array(Array(UInt64)))).new
      @array_array_string_values = Hash(String, Slice(Array(Array(String)))).new
      @array_array_nullable_string_values = Hash(String, WidePartArrayArrayNullableStringSlice).new
      @array_array_nullable_uint64_values = Hash(String, Slice(Array(Array(UInt64?)))).new
      @array_array_numeric_values = Hash(String, WidePartArrayArrayNumericSlice).new
      @array_array_nullable_numeric_values = Hash(String, WidePartArrayArrayNullableNumericSlice).new
      @array_numeric_values = Hash(String, WidePartArrayNumericSlice).new
      @array_nullable_numeric_values = Hash(String, WidePartArrayNullableNumericSlice).new
      @array_bool_values = Hash(String, WidePartArrayBoolSlice).new
      @array_nullable_bool_values = Hash(String, WidePartArrayNullableBoolSlice).new
      @array_tuple_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
      @array_tuple_nullable_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64?, String)))).new
      @array_tuple_uint64_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
      @variant_string_uint64_values = Hash(String, Slice(VariantStringUInt64Value)).new
      @variant_bool_string_uint64_values = Hash(String, Slice(VariantBoolStringUInt64Value)).new
      @tuple_string_values = Hash(String, Slice(Tuple(UInt64, String))).new
      @map_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
      @map_uint64_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
      @map_string_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64)))).new
      @map_string_array_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64))))).new
      @map_string_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))).new
      @map_string_array_nullable_string_values = Hash(String, Slice(Array(Tuple(String, Array(String?))))).new
      @map_uint64_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))).new
      @map_string_string_values = Hash(String, Slice(Array(Tuple(String, String)))).new
      @map_uint64_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))).new
      @map_string_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64?)))).new
      @map_uint64_nullable_string_values = Hash(String, Slice(Array(Tuple(UInt64, String?)))).new
      @map_string_nullable_string_values = Hash(String, Slice(Array(Tuple(String, String?)))).new
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
      @array_nullable_uint64_values = Hash(String, Slice(Array(UInt64?))).new
      @array_string_values = Hash(String, Slice(Array(String))).new
      @array_nullable_string_values = Hash(String, WidePartArrayNullableStringSlice).new
      @array_array_uint64_values = Hash(String, Slice(Array(Array(UInt64)))).new
      @array_array_string_values = Hash(String, Slice(Array(Array(String)))).new
      @array_array_nullable_string_values = Hash(String, WidePartArrayArrayNullableStringSlice).new
      @array_array_nullable_uint64_values = Hash(String, Slice(Array(Array(UInt64?)))).new
      @array_array_numeric_values = Hash(String, WidePartArrayArrayNumericSlice).new
      @array_array_nullable_numeric_values = Hash(String, WidePartArrayArrayNullableNumericSlice).new
      @array_numeric_values = Hash(String, WidePartArrayNumericSlice).new
      @array_nullable_numeric_values = Hash(String, WidePartArrayNullableNumericSlice).new
      @array_bool_values = Hash(String, WidePartArrayBoolSlice).new
      @array_nullable_bool_values = Hash(String, WidePartArrayNullableBoolSlice).new
      @array_tuple_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
      @array_tuple_nullable_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64?, String)))).new
      @array_tuple_uint64_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
      @variant_string_uint64_values = Hash(String, Slice(VariantStringUInt64Value)).new
      @variant_bool_string_uint64_values = Hash(String, Slice(VariantBoolStringUInt64Value)).new
      @tuple_string_values = Hash(String, Slice(Tuple(UInt64, String))).new
      @map_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
      @map_uint64_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
      @map_string_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64)))).new
      @map_string_array_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64))))).new
      @map_string_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))).new
      @map_string_array_nullable_string_values = Hash(String, Slice(Array(Tuple(String, Array(String?))))).new
      @map_uint64_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))).new
      @map_string_string_values = Hash(String, Slice(Array(Tuple(String, String)))).new
      @map_uint64_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))).new
      @map_string_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64?)))).new
      @map_uint64_nullable_string_values = Hash(String, Slice(Array(Tuple(UInt64, String?)))).new
      @map_string_nullable_string_values = Hash(String, Slice(Array(Tuple(String, String?)))).new
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
      @tuple_string_values : Hash(String, Slice(Tuple(UInt64, String))) = Hash(String, Slice(Tuple(UInt64, String))).new,
      map_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64, String)))) = Hash(String, Slice(Array(Tuple(UInt64, String)))).new,
      map_uint64_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64)))) = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new,
      array_nullable_uint64_values : Hash(String, Slice(Array(UInt64?))) = Hash(String, Slice(Array(UInt64?))).new,
      array_array_uint64_values : Hash(String, Slice(Array(Array(UInt64)))) = Hash(String, Slice(Array(Array(UInt64)))).new,
      array_array_nullable_uint64_values : Hash(String, Slice(Array(Array(UInt64?)))) = Hash(String, Slice(Array(Array(UInt64?)))).new,
      array_array_numeric_values : Hash(String, WidePartArrayArrayNumericSlice) = Hash(String, WidePartArrayArrayNumericSlice).new,
      array_array_nullable_numeric_values : Hash(String, WidePartArrayArrayNullableNumericSlice) = Hash(String, WidePartArrayArrayNullableNumericSlice).new,
      array_numeric_values : Hash(String, WidePartArrayNumericSlice) = Hash(String, WidePartArrayNumericSlice).new,
      array_nullable_numeric_values : Hash(String, WidePartArrayNullableNumericSlice) = Hash(String, WidePartArrayNullableNumericSlice).new,
      array_nullable_string_values : Hash(String, WidePartArrayNullableStringSlice) = Hash(String, WidePartArrayNullableStringSlice).new,
      @array_bool_values : Hash(String, WidePartArrayBoolSlice) = Hash(String, WidePartArrayBoolSlice).new,
      @array_nullable_bool_values : Hash(String, WidePartArrayNullableBoolSlice) = Hash(String, WidePartArrayNullableBoolSlice).new,
      @array_tuple_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64, String)))) = Hash(String, Slice(Array(Tuple(UInt64, String)))).new,
      @array_tuple_nullable_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64?, String)))) = Hash(String, Slice(Array(Tuple(UInt64?, String)))).new,
      map_string_uint64_values : Hash(String, Slice(Array(Tuple(String, UInt64)))) = Hash(String, Slice(Array(Tuple(String, UInt64)))).new,
      map_string_string_values : Hash(String, Slice(Array(Tuple(String, String)))) = Hash(String, Slice(Array(Tuple(String, String)))).new,
      map_uint64_nullable_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))) = Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))).new,
      map_string_nullable_uint64_values : Hash(String, Slice(Array(Tuple(String, UInt64?)))) = Hash(String, Slice(Array(Tuple(String, UInt64?)))).new,
      map_uint64_nullable_string_values : Hash(String, Slice(Array(Tuple(UInt64, String?)))) = Hash(String, Slice(Array(Tuple(UInt64, String?)))).new,
      map_string_nullable_string_values : Hash(String, Slice(Array(Tuple(String, String?)))) = Hash(String, Slice(Array(Tuple(String, String?)))).new,
      @array_tuple_uint64_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64)))) = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new,
      @variant_string_uint64_values : Hash(String, Slice(VariantStringUInt64Value)) = Hash(String, Slice(VariantStringUInt64Value)).new,
      @variant_bool_string_uint64_values : Hash(String, Slice(VariantBoolStringUInt64Value)) = Hash(String, Slice(VariantBoolStringUInt64Value)).new,
      @array_array_string_values : Hash(String, Slice(Array(Array(String)))) = Hash(String, Slice(Array(Array(String)))).new,
      @array_array_nullable_string_values : Hash(String, WidePartArrayArrayNullableStringSlice) = Hash(String, WidePartArrayArrayNullableStringSlice).new,
      map_string_array_uint64_values : Hash(String, Slice(Array(Tuple(String, Array(UInt64))))) = Hash(String, Slice(Array(Tuple(String, Array(UInt64))))).new,
      map_string_array_nullable_uint64_values : Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))) = Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))).new,
      map_uint64_array_nullable_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))) = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))).new,
      @map_string_array_nullable_string_values : Hash(String, Slice(Array(Tuple(String, Array(String?))))) = Hash(String, Slice(Array(Tuple(String, Array(String?))))).new,
    )
      @column_values = [] of WidePartNumericSlice
      @fixed_string_values = fixed_string_values
      @nullable_fixed_string_values = nullable_fixed_string_values
      @array_nullable_uint64_values = array_nullable_uint64_values
      @map_uint64_string_values = map_uint64_string_values
      @map_uint64_uint64_values = map_uint64_uint64_values
      @array_array_uint64_values = array_array_uint64_values
      @array_array_nullable_uint64_values = array_array_nullable_uint64_values
      @array_array_numeric_values = array_array_numeric_values
      @array_array_nullable_numeric_values = array_array_nullable_numeric_values
      @array_numeric_values = array_numeric_values
      @array_nullable_numeric_values = array_nullable_numeric_values
      @array_nullable_string_values = array_nullable_string_values
      @map_string_uint64_values = map_string_uint64_values
      @map_string_array_uint64_values = map_string_array_uint64_values
      @map_string_array_nullable_uint64_values = map_string_array_nullable_uint64_values
      @map_uint64_array_nullable_uint64_values = map_uint64_array_nullable_uint64_values
      @map_string_string_values = map_string_string_values
      @map_uint64_nullable_uint64_values = map_uint64_nullable_uint64_values
      @map_string_nullable_uint64_values = map_string_nullable_uint64_values
      @map_uint64_nullable_string_values = map_uint64_nullable_string_values
      @map_string_nullable_string_values = map_string_nullable_string_values
    end

    def column_names : Array(String)
      @column_names.dup
    end

    # Return the exact declaration for a selected column. Semantic values such
    # as DateTime64 ticks need this metadata to retain their precision label.
    def column_type_for(column : String) : String
      @column_types[column_index(column)]
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

    def time_seconds_for(column : String) : Slice(Int32)
      index = column_index(column)
      raise UnsupportedFormatError.new("Time accessor requires an exact Time column") unless @column_types[index] == "Time"
      return @typed_numeric_values[column].as(Slice(Int32)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int32))
    end

    def time64_ticks_for(column : String) : Slice(Int64)
      index = column_index(column)
      raise UnsupportedFormatError.new("Time64 accessor requires a canonical Time64(p) column") unless WidePart.time64_scale(@column_types[index])
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

    def int128_raw_for(column : String) : Slice(Int128)
      index = column_index(column)
      raise UnsupportedFormatError.new("raw Int128 accessor requires an exact Int128 column") unless @column_types[index] == "Int128"
      return @typed_numeric_values[column].as(Slice(Int128)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int128))
    end

    def uint128_raw_for(column : String) : Slice(UInt128)
      index = column_index(column)
      raise UnsupportedFormatError.new("raw UInt128 accessor requires an exact UInt128 column") unless @column_types[index] == "UInt128"
      return @typed_numeric_values[column].as(Slice(UInt128)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(UInt128))
    end

    def int256_raw_for(column : String) : Slice(Int256Value)
      index = column_index(column)
      raise UnsupportedFormatError.new("raw Int256 accessor requires an exact Int256 column") unless @column_types[index] == "Int256"
      return @typed_numeric_values[column].as(Slice(Int256Value)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int256Value))
    end

    def uint256_raw_for(column : String) : Slice(UInt256Value)
      index = column_index(column)
      raise UnsupportedFormatError.new("raw UInt256 accessor requires an exact UInt256 column") unless @column_types[index] == "UInt256"
      return @typed_numeric_values[column].as(Slice(UInt256Value)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(UInt256Value))
    end

    def nullable_decimal128_raw_for(column : String) : Slice(Int128?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires canonical Nullable(Decimal(38, S))") unless WidePart.nullable_decimal128_scale(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(Int128?))) || raise(UnsupportedFormatError.new("Nullable(Decimal128) column was not materialized in this batch"))
    end

    def nullable_int128_raw_for(column : String) : Slice(Int128?)
      index = column_index(column)
      raise UnsupportedFormatError.new("raw Int128 accessor requires exact Nullable(Int128)") unless @column_types[index] == "Nullable(Int128)"
      @nullable_values[column]?.try(&.as(Slice(Int128?))) || raise(UnsupportedFormatError.new("Nullable(Int128) column was not materialized in this batch"))
    end

    def nullable_uint128_raw_for(column : String) : Slice(UInt128?)
      index = column_index(column)
      raise UnsupportedFormatError.new("raw UInt128 accessor requires exact Nullable(UInt128)") unless @column_types[index] == "Nullable(UInt128)"
      @nullable_values[column]?.try(&.as(Slice(UInt128?))) || raise(UnsupportedFormatError.new("Nullable(UInt128) column was not materialized in this batch"))
    end

    def nullable_int256_raw_for(column : String) : Slice(Int256Value?)
      index = column_index(column)
      raise UnsupportedFormatError.new("raw Int256 accessor requires exact Nullable(Int256)") unless @column_types[index] == "Nullable(Int256)"
      @nullable_values[column]?.try(&.as(Slice(Int256Value?))) || raise(UnsupportedFormatError.new("Nullable(Int256) column was not materialized in this batch"))
    end

    def nullable_uint256_raw_for(column : String) : Slice(UInt256Value?)
      index = column_index(column)
      raise UnsupportedFormatError.new("raw UInt256 accessor requires exact Nullable(UInt256)") unless @column_types[index] == "Nullable(UInt256)"
      @nullable_values[column]?.try(&.as(Slice(UInt256Value?))) || raise(UnsupportedFormatError.new("Nullable(UInt256) column was not materialized in this batch"))
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

    def bfloat16s_for(column : String) : Slice(BFloat16Value)
      index = column_index(column)
      raise UnsupportedFormatError.new("BFloat16 accessor requires an exact BFloat16 column") unless @column_types[index] == "BFloat16"
      return @typed_numeric_values[column].as(Slice(BFloat16Value)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(BFloat16Value))
    end

    def nullable_ipv6s_for(column : String) : Slice(IPv6Value?)
      index = column_index(column)
      raise UnsupportedFormatError.new("IPv6 accessor requires an exact Nullable(IPv6) column") unless WidePart.supports_nullable_ipv6_type?(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(IPv6Value?))) || raise(UnsupportedFormatError.new("Nullable(IPv6) column was not materialized in this batch"))
    end

    def nullable_bfloat16s_for(column : String) : Slice(BFloat16Value?)
      index = column_index(column)
      raise UnsupportedFormatError.new("BFloat16 accessor requires an exact Nullable(BFloat16) column") unless @column_types[index] == "Nullable(BFloat16)"
      @nullable_values[column]?.try(&.as(Slice(BFloat16Value?))) || raise(UnsupportedFormatError.new("Nullable(BFloat16) column was not materialized in this batch"))
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

    # Return a typed Array(T) slice only for an exact matching one-level
    # numeric declaration. Existing specialized array accessors remain intact.
    def array_numeric_values(column : String, type : T.class) : Slice(Array(T)) forall T
      index = column_index(column)
      type_name = WidePart.array_numeric_type_name(type)
      raise UnsupportedFormatError.new("typed Array accessor requires an exact Array(T) numeric column") unless WidePart.numeric_array_element_type(@column_types[index]) == type_name
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Array numeric column was not materialized in this batch"))
      values.as(Slice(Array(T)))
    end

    def array_date_codes_for(column : String) : Slice(Array(UInt16))
      array_temporal_values_for(column, "Date", UInt16)
    end

    def array_date32_codes_for(column : String) : Slice(Array(Int32))
      array_temporal_values_for(column, "Date32", Int32)
    end

    def array_datetime_seconds_for(column : String) : Slice(Array(UInt32))
      array_temporal_values_for(column, "DateTime", UInt32)
    end

    def array_datetime64_ticks_for(column : String) : Slice(Array(Int64))
      index = column_index(column)
      scale = WidePart.array_datetime64_scale(@column_types[index]) || raise(UnsupportedFormatError.new("typed temporal Array accessor requires a canonical Array(DateTime64(p)) column"))
      array_temporal_values_for(column, "DateTime64(#{scale})", Int64)
    end

    def array_time_seconds_for(column : String) : Slice(Array(Int32))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Time Array accessor requires an exact Array(Time) declaration") unless WidePart.time_array_element_type(@column_types[index]) == "Time"
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Time Array column was not materialized in this batch"))
      values.as(Slice(Array(Int32)))
    end

    def array_time64_ticks_for(column : String) : Slice(Array(Int64))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Time64 Array accessor requires a canonical Array(Time64(p)) declaration") unless WidePart.array_time64_scale(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Time64 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int64)))
    end

    def array_nullable_date_codes_for(column : String) : Slice(Array(UInt16?))
      array_nullable_temporal_values_for(column, "Date", UInt16)
    end

    def array_nullable_date32_codes_for(column : String) : Slice(Array(Int32?))
      array_nullable_temporal_values_for(column, "Date32", Int32)
    end

    def array_nullable_datetime_seconds_for(column : String) : Slice(Array(UInt32?))
      array_nullable_temporal_values_for(column, "DateTime", UInt32)
    end

    def array_nullable_datetime64_ticks_for(column : String) : Slice(Array(Int64?))
      index = column_index(column)
      scale = WidePart.nullable_array_datetime64_scale(@column_types[index]) || raise(UnsupportedFormatError.new("typed nullable temporal Array accessor requires a canonical Array(Nullable(DateTime64(p))) column"))
      array_nullable_temporal_values_for(column, "DateTime64(#{scale})", Int64)
    end

    def array_nullable_time_seconds_for(column : String) : Slice(Array(Int32?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed nullable Time Array accessor requires an exact Array(Nullable(Time)) declaration") unless WidePart.nullable_time_array_element_type(@column_types[index]) == "Time"
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Time Array column was not materialized in this batch"))
      values.as(Slice(Array(Int32?)))
    end

    def array_nullable_time64_ticks_for(column : String) : Slice(Array(Int64?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed nullable Time64 Array accessor requires a canonical Array(Nullable(Time64(p))) declaration") unless WidePart.nullable_array_time64_scale(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Time64 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int64?)))
    end

    def array_uuids_for(column : String) : Slice(Array(UUIDValue))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Array(UUID) accessor requires an exact Array(UUID) declaration") unless WidePart.uuid_array_element_type(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(UUID) column was not materialized in this batch"))
      values.as(Slice(Array(UUIDValue)))
    end

    def array_nullable_uuids_for(column : String) : Slice(Array(UUIDValue?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Array(Nullable(UUID)) accessor requires an exact declaration") unless WidePart.nullable_uuid_array_element_type(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Nullable(UUID)) column was not materialized in this batch"))
      values.as(Slice(Array(UUIDValue?)))
    end

    def array_ipv4s_for(column : String) : Slice(Array(IPv4Value))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Array(IPv4) accessor requires an exact declaration") unless WidePart.ipv4_array_element_type(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(IPv4) column was not materialized in this batch"))
      values.as(Slice(Array(IPv4Value)))
    end

    def array_nullable_ipv4s_for(column : String) : Slice(Array(IPv4Value?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Array(Nullable(IPv4)) accessor requires an exact declaration") unless WidePart.nullable_ipv4_array_element_type(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Nullable(IPv4)) column was not materialized in this batch"))
      values.as(Slice(Array(IPv4Value?)))
    end

    def array_ipv6s_for(column : String) : Slice(Array(IPv6Value))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Array(IPv6) accessor requires an exact declaration") unless WidePart.ipv6_array_element_type(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(IPv6) column was not materialized in this batch"))
      values.as(Slice(Array(IPv6Value)))
    end

    def array_nullable_ipv6s_for(column : String) : Slice(Array(IPv6Value?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Array(Nullable(IPv6)) accessor requires an exact declaration") unless WidePart.nullable_ipv6_array_element_type(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Nullable(IPv6)) column was not materialized in this batch"))
      values.as(Slice(Array(IPv6Value?)))
    end

    def array_bfloat16s_for(column : String) : Slice(Array(BFloat16Value))
      array_numeric_values(column, BFloat16Value)
    end

    def array_nullable_bfloat16s_for(column : String) : Slice(Array(BFloat16Value?))
      array_nullable_numeric_values(column, BFloat16Value)
    end

    def array_enum8_codes_for(column : String) : Slice(Array(Int8))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Array(Enum8) accessor requires an exact declaration") unless WidePart.array_enum8_codes(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Enum8) column was not materialized in this batch"))
      values.as(Slice(Array(Int8)))
    end

    def array_nullable_enum8_codes_for(column : String) : Slice(Array(Int8?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Array(Nullable(Enum8)) accessor requires an exact declaration") unless WidePart.array_nullable_enum8_codes(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Nullable(Enum8)) column was not materialized in this batch"))
      values.as(Slice(Array(Int8?)))
    end

    def array_enum16_codes_for(column : String) : Slice(Array(Int16))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Array(Enum16) accessor requires an exact declaration") unless WidePart.array_enum16_codes(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Enum16) column was not materialized in this batch"))
      values.as(Slice(Array(Int16)))
    end

    def array_nullable_enum16_codes_for(column : String) : Slice(Array(Int16?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Array(Nullable(Enum16)) accessor requires an exact declaration") unless WidePart.array_nullable_enum16_codes(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Nullable(Enum16)) column was not materialized in this batch"))
      values.as(Slice(Array(Int16?)))
    end

    def array_decimal32_raw_for(column : String) : Slice(Array(Int32))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Decimal32 Array accessor requires an exact Array(Decimal(9, S)) declaration") unless WidePart.array_decimal32_scale(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal32 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int32)))
    end

    def array_nullable_decimal32_raw_for(column : String) : Slice(Array(Int32?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed nullable Decimal32 Array accessor requires an exact Array(Nullable(Decimal(9, S))) declaration") unless WidePart.array_nullable_decimal32_scale(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal32 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int32?)))
    end

    def array_decimal64_raw_for(column : String) : Slice(Array(Int64))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Decimal64 Array accessor requires an exact Array(Decimal(18, S)) declaration") unless WidePart.array_decimal64_scale(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal64 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int64)))
    end

    def array_nullable_decimal64_raw_for(column : String) : Slice(Array(Int64?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed nullable Decimal64 Array accessor requires an exact Array(Nullable(Decimal(18, S))) declaration") unless WidePart.array_nullable_decimal64_scale(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal64 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int64?)))
    end

    def array_decimal128_raw_for(column : String) : Slice(Array(Int128))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Decimal128 Array accessor requires an exact Array(Decimal(38, S)) declaration") unless WidePart.array_decimal128_scale(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal128 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int128)))
    end

    def array_nullable_decimal128_raw_for(column : String) : Slice(Array(Int128?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed nullable Decimal128 Array accessor requires an exact Array(Nullable(Decimal(38, S))) declaration") unless WidePart.array_nullable_decimal128_scale(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal128 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int128?)))
    end

    def array_decimal256_raw_for(column : String) : Slice(Array(Decimal256Value))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Decimal256 Array accessor requires an exact Array(Decimal(76, S)) declaration") unless WidePart.array_decimal256_scale(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal256 Array column was not materialized in this batch"))
      values.as(Slice(Array(Decimal256Value)))
    end

    def array_nullable_decimal256_raw_for(column : String) : Slice(Array(Decimal256Value?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed nullable Decimal256 Array accessor requires an exact Array(Nullable(Decimal(76, S))) declaration") unless WidePart.array_nullable_decimal256_scale(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal256 Array column was not materialized in this batch"))
      values.as(Slice(Array(Decimal256Value?)))
    end

    # Return a nullable typed Array(T) view only for an exact
    # Array(Nullable(T)) numeric declaration.
    def array_nullable_numeric_values(column : String, type : T.class) : Slice(Array(T?)) forall T
      index = column_index(column)
      type_name = WidePart.array_numeric_type_name(type)
      unless WidePart.nullable_numeric_array_element_type(@column_types[index]) == type_name
        raise UnsupportedFormatError.new("typed nullable Array accessor requires an exact Array(Nullable(T)) numeric column")
      end
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("Array nullable numeric column was not materialized in this batch"))
      values.as(Slice(Array(T?)))
    end

    private def array_temporal_values_for(column : String, element_type : String, type : T.class) : Slice(Array(T)) forall T
      index = column_index(column)
      unless WidePart.temporal_array_element_type(@column_types[index]) == element_type &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed temporal Array accessor requires an exact semantic temporal column")
      end
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("temporal Array column was not materialized in this batch"))
      values.as(Slice(Array(T)))
    end

    private def array_nullable_temporal_values_for(column : String, element_type : String, type : T.class) : Slice(Array(T?)) forall T
      index = column_index(column)
      unless WidePart.nullable_temporal_array_element_type(@column_types[index]) == element_type &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nullable temporal Array accessor requires an exact semantic temporal column")
      end
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable temporal Array column was not materialized in this batch"))
      values.as(Slice(Array(T?)))
    end

    private def array_array_temporal_values_for(column : String, element_type : String, type : T.class) : Slice(Array(Array(T))) forall T
      index = column_index(column)
      unless WidePart.array_array_temporal_element_type(@column_types[index]) == element_type &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed temporal nested Array accessor requires an exact semantic temporal column")
      end
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("temporal nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(T))))
    end

    private def array_array_nullable_temporal_values_for(column : String, element_type : String, type : T.class) : Slice(Array(Array(T?))) forall T
      index = column_index(column)
      unless WidePart.array_array_nullable_temporal_element_type(@column_types[index]) == element_type &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nullable temporal nested Array accessor requires an exact semantic temporal column")
      end
      values = @array_array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable temporal nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(T?))))
    end

    private def array_array_time_values_for(column : String, element_type : String, type : T.class) : Slice(Array(Array(T))) forall T
      index = column_index(column)
      unless WidePart.array_array_time_element_type(@column_types[index]) == element_type &&
             WidePart.time_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nested Time Array accessor requires an exact semantic Time column")
      end
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("nested Time Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(T))))
    end

    private def array_array_nullable_time_values_for(column : String, element_type : String, type : T.class) : Slice(Array(Array(T?))) forall T
      index = column_index(column)
      unless WidePart.array_array_nullable_time_element_type(@column_types[index]) == element_type &&
             WidePart.time_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nested nullable Time Array accessor requires an exact semantic Time column")
      end
      values = @array_array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nested nullable Time Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(T?))))
    end

    def array_array_uint64s_for(column : String) : Slice(Array(Array(UInt64)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Array(UInt64)) accessor requires an exact Array(Array(UInt64)) column") unless @column_types[index] == "Array(Array(UInt64))"
      @array_array_uint64_values[column]? || raise(UnsupportedFormatError.new("Array(Array(UInt64)) column was not materialized in this batch"))
    end

    def array_array_strings_for(column : String) : Slice(Array(Array(String)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Array(String)) accessor requires an exact Array(Array(String)) column") unless @column_types[index] == "Array(Array(String))"
      @array_array_string_values[column]? || raise(UnsupportedFormatError.new("Array(Array(String)) column was not materialized in this batch"))
    end

    def array_array_nullable_strings_for(column : String) : Slice(Array(Array(String?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Array(Nullable(String))) accessor requires the exact W61 column type") unless @column_types[index] == "Array(Array(Nullable(String)))"
      @array_array_nullable_string_values[column]? || raise(UnsupportedFormatError.new("Array(Array(Nullable(String))) column was not materialized in this batch"))
    end

    def array_array_nullable_uint64s_for(column : String) : Slice(Array(Array(UInt64?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Array(Nullable(UInt64))) accessor requires an exact Array(Array(Nullable(UInt64))) column") unless @column_types[index] == "Array(Array(Nullable(UInt64)))"
      @array_array_nullable_uint64_values[column]? || raise(UnsupportedFormatError.new("Array(Array(Nullable(UInt64))) column was not materialized in this batch"))
    end

    # Return a typed two-level numeric Array view only for an exact admitted
    # leaf type, including the bounded wide numeric family.
    def array_array_numeric_values(column : String, type : T.class) : Slice(Array(Array(T))) forall T
      index = column_index(column)
      type_name = WidePart.array_numeric_type_name(type)
      unless WidePart.array_array_numeric_element_type(@column_types[index]) == type_name
        raise UnsupportedFormatError.new("typed Array(Array) accessor requires an exact admitted numeric column")
      end
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Array) numeric column was not materialized in this batch"))
      values.as(Slice(Array(Array(T))))
    end

    # Return a typed nested nullable numeric view only for the exact admitted
    # Array(Array(Nullable(T))) declaration and matching admitted leaf type.
    def array_array_nullable_numeric_values(column : String, type : T.class) : Slice(Array(Array(T?))) forall T
      index = column_index(column)
      type_name = WidePart.array_numeric_type_name(type)
      unless WidePart.array_array_nullable_numeric_element_type(@column_types[index]) == type_name
        raise UnsupportedFormatError.new("typed Array(Array(Nullable(T))) accessor requires an exact nested nullable numeric column")
      end
      values = @array_array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Array(Nullable(T))) numeric column was not materialized in this batch"))
      values.as(Slice(Array(Array(T?))))
    end

    # Decimal raw accessors keep Decimal declarations distinct from same-width
    # signed integers while sharing the bounded nested-numeric batch storage.
    def array_array_decimal32_raw_for(column : String) : Slice(Array(Array(Int32)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal32 accessor requires exact Array(Array(Decimal(9, S)))") unless WidePart.array_array_decimal32_scale(@column_types[index])
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal32 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int32))))
    end

    def array_array_decimal64_raw_for(column : String) : Slice(Array(Array(Int64)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires exact Array(Array(Decimal(18, S)))") unless WidePart.array_array_decimal64_scale(@column_types[index])
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal64 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int64))))
    end

    def array_array_decimal128_raw_for(column : String) : Slice(Array(Array(Int128)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires exact Array(Array(Decimal(38, S)))") unless WidePart.array_array_decimal128_scale(@column_types[index])
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal128 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int128))))
    end

    def array_array_decimal256_raw_for(column : String) : Slice(Array(Array(Decimal256Value)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal256 accessor requires exact Array(Array(Decimal(76, S)))") unless WidePart.array_array_decimal256_scale(@column_types[index])
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal256 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Decimal256Value))))
    end

    def array_array_nullable_decimal32_raw_for(column : String) : Slice(Array(Array(Int32?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal32 accessor requires exact Array(Array(Nullable(Decimal(9, S))))") unless WidePart.array_array_nullable_decimal32_scale(@column_types[index])
      values = @array_array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal32 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int32?))))
    end

    def array_array_nullable_decimal64_raw_for(column : String) : Slice(Array(Array(Int64?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires exact Array(Array(Nullable(Decimal(18, S))))") unless WidePart.array_array_nullable_decimal64_scale(@column_types[index])
      values = @array_array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal64 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int64?))))
    end

    def array_array_nullable_decimal128_raw_for(column : String) : Slice(Array(Array(Int128?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires exact Array(Array(Nullable(Decimal(38, S))))") unless WidePart.array_array_nullable_decimal128_scale(@column_types[index])
      values = @array_array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal128 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int128?))))
    end

    def array_array_nullable_decimal256_raw_for(column : String) : Slice(Array(Array(Decimal256Value?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal256 accessor requires exact Array(Array(Nullable(Decimal(76, S))))") unless WidePart.array_array_nullable_decimal256_scale(@column_types[index])
      values = @array_array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal256 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Decimal256Value?))))
    end

    # Temporal nested leaves remain semantically distinct from their same-width
    # integer carriers. The raw code/tick return types preserve ClickHouse's
    # stored representation without calendar conversion.
    def array_array_date_codes_for(column : String) : Slice(Array(Array(UInt16)))
      array_array_temporal_values_for(column, "Date", UInt16)
    end

    def array_array_date32_codes_for(column : String) : Slice(Array(Array(Int32)))
      array_array_temporal_values_for(column, "Date32", Int32)
    end

    def array_array_datetime_seconds_for(column : String) : Slice(Array(Array(UInt32)))
      array_array_temporal_values_for(column, "DateTime", UInt32)
    end

    def array_array_datetime64_ticks_for(column : String) : Slice(Array(Array(Int64)))
      index = column_index(column)
      scale = WidePart.array_array_datetime64_scale(@column_types[index]) ||
              raise(UnsupportedFormatError.new("typed temporal nested Array accessor requires canonical Array(Array(DateTime64(p)))"))
      array_array_temporal_values_for(column, "DateTime64(#{scale})", Int64)
    end

    def array_array_nullable_date_codes_for(column : String) : Slice(Array(Array(UInt16?)))
      array_array_nullable_temporal_values_for(column, "Date", UInt16)
    end

    def array_array_nullable_date32_codes_for(column : String) : Slice(Array(Array(Int32?)))
      array_array_nullable_temporal_values_for(column, "Date32", Int32)
    end

    def array_array_nullable_datetime_seconds_for(column : String) : Slice(Array(Array(UInt32?)))
      array_array_nullable_temporal_values_for(column, "DateTime", UInt32)
    end

    def array_array_nullable_datetime64_ticks_for(column : String) : Slice(Array(Array(Int64?)))
      index = column_index(column)
      scale = WidePart.array_array_nullable_datetime64_scale(@column_types[index]) ||
              raise(UnsupportedFormatError.new("typed nullable temporal nested Array accessor requires canonical Array(Array(Nullable(DateTime64(p))))"))
      array_array_nullable_temporal_values_for(column, "DateTime64(#{scale})", Int64)
    end

    def array_array_time_seconds_for(column : String) : Slice(Array(Array(Int32)))
      array_array_time_values_for(column, "Time", Int32)
    end

    def array_array_time64_ticks_for(column : String) : Slice(Array(Array(Int64)))
      index = column_index(column)
      scale = WidePart.array_array_time64_scale(@column_types[index]) ||
              raise(UnsupportedFormatError.new("typed nested Time64 accessor requires canonical Array(Array(Time64(p)))"))
      array_array_time_values_for(column, "Time64(#{scale})", Int64)
    end

    def array_array_nullable_time_seconds_for(column : String) : Slice(Array(Array(Int32?)))
      array_array_nullable_time_values_for(column, "Time", Int32)
    end

    def array_array_nullable_time64_ticks_for(column : String) : Slice(Array(Array(Int64?)))
      index = column_index(column)
      scale = WidePart.array_array_nullable_time64_scale(@column_types[index]) ||
              raise(UnsupportedFormatError.new("typed nested nullable Time64 accessor requires canonical Array(Array(Nullable(Time64(p))))"))
      array_array_nullable_time_values_for(column, "Time64(#{scale})", Int64)
    end

    def array_strings_for(column : String) : Slice(Array(String))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(String) accessor requires an exact Array(String) column") unless @column_types[index] == "Array(String)"
      @array_string_values[column]? || raise(UnsupportedFormatError.new("Array(String) column was not materialized in this batch"))
    end

    def array_tuple_uint64_string_for(column : String) : Slice(Array(Tuple(UInt64, String)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Tuple(UInt64, String)) accessor requires the exact W51 declaration") unless @column_types[index] == WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING
      @array_tuple_uint64_string_values[column]? || raise(UnsupportedFormatError.new("Array(Tuple(UInt64, String)) column was not materialized in this batch"))
    end

    def array_tuple_nullable_uint64_string_for(column : String) : Slice(Array(Tuple(UInt64?, String)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Tuple(Nullable(UInt64), String)) accessor requires the exact W51 declaration") unless @column_types[index] == WideTypePlan::TYPE_ARRAY_TUPLE_NULLABLE_UINT64_STRING
      @array_tuple_nullable_uint64_string_values[column]? || raise(UnsupportedFormatError.new("Array(Tuple(Nullable(UInt64), String)) column was not materialized in this batch"))
    end

    def array_tuple_uint64_uint64_for(column : String) : Slice(Array(Tuple(UInt64, UInt64)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Tuple(UInt64, UInt64)) accessor requires the exact W55 declaration") unless @column_types[index] == WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_UINT64
      @array_tuple_uint64_uint64_values[column]? || raise(UnsupportedFormatError.new("Array(Tuple(UInt64, UInt64)) column was not materialized in this batch"))
    end

    def variant_string_uint64_for(column : String) : Slice(VariantStringUInt64Value)
      index = column_index(column)
      raise UnsupportedFormatError.new("Variant accessor requires exact Variant(String, UInt64) metadata") unless @column_types[index] == "Variant(String, UInt64)"
      @variant_string_uint64_values[column]? || raise(UnsupportedFormatError.new("Variant column was not materialized in this batch"))
    end

    def variant_bool_string_uint64_for(column : String) : Slice(VariantBoolStringUInt64Value)
      index = column_index(column)
      raise UnsupportedFormatError.new("Variant accessor requires exact Variant(Bool, String, UInt64) metadata") unless @column_types[index] == WideVariantBoolStringUInt64TypePlan::TYPE
      @variant_bool_string_uint64_values[column]? || raise(UnsupportedFormatError.new("Variant column was not materialized in this batch"))
    end

    def array_nullable_strings_for(column : String) : WidePartArrayNullableStringSlice
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Nullable(String)) accessor requires an exact Array(Nullable(String)) column") unless @column_types[index] == "Array(Nullable(String))"
      @array_nullable_string_values[column]? || raise(UnsupportedFormatError.new("Array(Nullable(String)) column was not materialized in this batch"))
    end

    def array_fixed_strings_for(column : String) : Slice(Array(String))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(FixedString(N)) accessor requires an exact supported column") unless WidePart.array_fixed_string_width(@column_types[index])
      @array_string_values[column]? || raise(UnsupportedFormatError.new("Array(FixedString(N)) column was not materialized in this batch"))
    end

    def array_nullable_fixed_strings_for(column : String) : WidePartArrayNullableStringSlice
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Nullable(FixedString(N))) accessor requires an exact supported column") unless WidePart.array_nullable_fixed_string_width(@column_types[index])
      @array_nullable_string_values[column]? || raise(UnsupportedFormatError.new("Array(Nullable(FixedString(N))) column was not materialized in this batch"))
    end

    def array_bools_for(column : String) : WidePartArrayBoolSlice
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Bool) accessor requires an exact Array(Bool) column") unless WidePart.supports_array_bool_type?(@column_types[index])
      @array_bool_values[column]? || raise(UnsupportedFormatError.new("Array(Bool) column was not materialized in this batch"))
    end

    def array_nullable_bools_for(column : String) : WidePartArrayNullableBoolSlice
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Nullable(Bool)) accessor requires an exact Array(Nullable(Bool)) column") unless WidePart.supports_array_nullable_bool_type?(@column_types[index])
      @array_nullable_bool_values[column]? || raise(UnsupportedFormatError.new("Array(Nullable(Bool)) column was not materialized in this batch"))
    end

    def array_nullable_uint64s_for(column : String) : Slice(Array(UInt64?))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Nullable(UInt64)) accessor requires an exact Array(Nullable(UInt64)) column") unless @column_types[index] == "Array(Nullable(UInt64))"
      @array_nullable_uint64_values[column]? || raise(UnsupportedFormatError.new("Array(Nullable(UInt64)) column was not materialized in this batch"))
    end

    def tuples_for(column : String) : Slice(Tuple(UInt64, String))
      index = column_index(column)
      raise UnsupportedFormatError.new("Tuple accessor requires the exact named Tuple(a UInt64, b String) column") unless WidePart.supports_tuple_uint64_string_type?(@column_types[index])
      @tuple_string_values[column]? || raise(UnsupportedFormatError.new("Tuple column was not materialized in this batch"))
    end

    def map_uint64_strings_for(column : String) : Slice(Array(Tuple(UInt64, String)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, String) column") unless WidePart.supports_map_uint64_string_type?(@column_types[index])
      @map_uint64_string_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_uint64_uint64s_for(column : String) : Slice(Array(Tuple(UInt64, UInt64)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, UInt64) column") unless WidePart.supports_map_uint64_uint64_type?(@column_types[index])
      @map_uint64_uint64_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_string_uint64s_for(column : String) : Slice(Array(Tuple(String, UInt64)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, UInt64) column") unless WidePart.supports_map_string_uint64_type?(@column_types[index])
      @map_string_uint64_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_string_array_uint64s_for(column : String) : Slice(Array(Tuple(String, Array(UInt64))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(UInt64)) column") unless WidePart.supports_map_string_array_uint64_type?(@column_types[index])
      @map_string_array_uint64_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_string_array_nullable_uint64s_for(column : String) : Slice(Array(Tuple(String, Array(UInt64?))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(Nullable(UInt64))) column") unless WidePart.supports_map_string_array_nullable_uint64_type?(@column_types[index])
      @map_string_array_nullable_uint64_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_string_array_nullable_strings_for(column : String) : Slice(Array(Tuple(String, Array(String?))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(Nullable(String))) column") unless WidePart.supports_map_string_array_nullable_string_type?(@column_types[index])
      @map_string_array_nullable_string_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_uint64_array_nullable_uint64s_for(column : String) : Slice(Array(Tuple(UInt64, Array(UInt64?))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Array(Nullable(UInt64))) column") unless WidePart.supports_map_uint64_array_nullable_uint64_type?(@column_types[index])
      @map_uint64_array_nullable_uint64_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_string_strings_for(column : String) : Slice(Array(Tuple(String, String)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, String) column") unless WidePart.supports_map_string_string_type?(@column_types[index])
      @map_string_string_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_uint64_nullable_uint64s_for(column : String) : Slice(Array(Tuple(UInt64, UInt64?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Nullable(UInt64)) column") unless WidePart.supports_map_uint64_nullable_uint64_type?(@column_types[index])
      @map_uint64_nullable_uint64_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_string_nullable_uint64s_for(column : String) : Slice(Array(Tuple(String, UInt64?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Nullable(UInt64)) column") unless WidePart.supports_map_string_nullable_uint64_type?(@column_types[index])
      @map_string_nullable_uint64_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_uint64_nullable_strings_for(column : String) : Slice(Array(Tuple(UInt64, String?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Nullable(String)) column") unless WidePart.supports_map_uint64_nullable_string_type?(@column_types[index])
      @map_uint64_nullable_string_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_string_nullable_strings_for(column : String) : Slice(Array(Tuple(String, String?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Nullable(String)) column") unless WidePart.supports_map_string_nullable_string_type?(@column_types[index])
      @map_string_nullable_string_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
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

    def nullable_time_seconds_for(column : String) : Slice(Int32?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Nullable(Time) accessor requires an exact Nullable(Time) column") unless @column_types[index] == "Nullable(Time)"
      @nullable_values[column]?.try(&.as(Slice(Int32?))) || raise(UnsupportedFormatError.new("Nullable(Time) column was not materialized in this batch"))
    end

    def nullable_time64_ticks_for(column : String) : Slice(Int64?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Nullable(Time64) accessor requires a canonical Nullable(Time64(p)) column") unless WidePart.nullable_time64_scale(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(Int64?))) || raise(UnsupportedFormatError.new("Nullable(Time64) column was not materialized in this batch"))
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
            preflight_array_numeric_bytes = Hash(String, UInt64).new
            preflight_array_nullable_numeric_bytes = Hash(String, UInt64).new
            preflight_array_uuid_bytes = Hash(String, UInt64).new
            preflight_array_nullable_uuid_bytes = Hash(String, UInt64).new
            preflight_array_array_uint64_bytes = Hash(String, UInt64).new
            preflight_array_array_string_bytes = Hash(String, UInt64).new
            preflight_array_array_nullable_string_bytes = Hash(String, UInt64).new
            preflight_array_array_nullable_uint64_bytes = Hash(String, UInt64).new
            preflight_array_array_numeric_bytes = Hash(String, UInt64).new
            preflight_array_array_nullable_numeric_bytes = Hash(String, UInt64).new
            preflight_array_nullable_string_raw_bytes = Hash(String, UInt64).new
            preflight_array_nullable_string_charge_bytes = Hash(String, UInt64).new
            preflight_array_tuple_bytes = Hash(String, UInt64).new
            preflight_variant_string_uint64_raw_bytes = Hash(String, UInt64).new
            preflight_variant_string_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_variant_bool_string_uint64_raw_bytes = Hash(String, UInt64).new
            preflight_variant_bool_string_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_array_fixed_string_raw_bytes = Hash(String, UInt64).new
            preflight_array_bool_raw_bytes = Hash(String, UInt64).new
            preflight_array_nullable_bool_raw_bytes = Hash(String, UInt64).new
            preflight_map_string_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_array_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_array_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_array_nullable_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_array_nullable_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_array_nullable_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_array_nullable_string_charge_bytes = Hash(String, UInt64).new
            preflight_map_uint64_array_nullable_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_uint64_array_nullable_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_string_charge_bytes = Hash(String, UInt64).new
            preflight_map_uint64_nullable_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_uint64_nullable_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_nullable_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_nullable_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_uint64_nullable_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_uint64_nullable_string_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_nullable_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_nullable_string_charge_bytes = Hash(String, UInt64).new
            part.readers.each do |selected|
              if selected.column_type == "Variant(String, UInt64)"
                raw_bytes, charge_bytes = selected.reader.variant_string_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_variant_string_uint64_raw_bytes[selected.name] = raw_bytes
                preflight_variant_string_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif selected.column_type == WideVariantBoolStringUInt64TypePlan::TYPE
                raw_bytes, charge_bytes = selected.reader.variant_bool_string_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_variant_bool_string_uint64_raw_bytes[selected.name] = raw_bytes
                preflight_variant_bool_string_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif plan = WideTypePlan.admitted(selected.column_type)
                bytes = case plan.shape
                        when WideTypePlan::Shape::ArrayArrayString
                          selected.reader.array_array_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        when WideTypePlan::Shape::ArrayArrayNullableString
                          selected.reader.array_array_nullable_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        when WideTypePlan::Shape::ArrayTupleUInt64String
                          selected.reader.preflight_array_tuple_uint64_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        when WideTypePlan::Shape::ArrayTupleNullableUInt64String
                          selected.reader.preflight_array_tuple_nullable_uint64_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        when WideTypePlan::Shape::ArrayTupleUInt64UInt64
                          selected.reader.preflight_array_tuple_uint64_uint64_mark_range_raw_bytes(selected.name, mark_index, 1)
                        else
                          raise UnsupportedFormatError.new("unsupported admitted Array(Tuple) plan")
                        end
                if plan.shape == WideTypePlan::Shape::ArrayArrayString
                  preflight_array_array_string_bytes[selected.name] = bytes
                elsif plan.shape == WideTypePlan::Shape::ArrayArrayNullableString
                  preflight_array_array_nullable_string_bytes[selected.name] = bytes
                else
                  preflight_array_tuple_bytes[selected.name] = bytes
                end
              elsif selected.column_type == "String" || WidePart.supports_nullable_string_type?(selected.column_type)
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
              elsif width = WidePart.array_fixed_string_width(selected.column_type)
                raw_bytes = selected.reader.array_fixed_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_fixed_string_raw_bytes[selected.name] = raw_bytes
                bytes = array_fixed_string_charge_bytes(raw_bytes, width, mark_rows, false)
              elsif width = WidePart.array_nullable_fixed_string_width(selected.column_type)
                raw_bytes = selected.reader.array_nullable_fixed_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_fixed_string_raw_bytes[selected.name] = raw_bytes
                bytes = array_fixed_string_charge_bytes(raw_bytes, width, mark_rows, true)
              elsif WidePart.supports_array_bool_type?(selected.column_type)
                bytes = selected.reader.array_bool_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_bool_raw_bytes[selected.name] = bytes
              elsif WidePart.supports_array_nullable_bool_type?(selected.column_type)
                bytes = selected.reader.array_nullable_bool_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_bool_raw_bytes[selected.name] = bytes
              elsif WidePart.time_array_element_type(selected.column_type)
                bytes = selected.reader.array_time_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.nullable_time_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_time_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.temporal_array_element_type(selected.column_type)
                bytes = selected.reader.array_temporal_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.nullable_temporal_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_temporal_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_enum8_codes(selected.column_type)
                bytes = selected.reader.array_enum8_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_enum8_codes(selected.column_type)
                bytes = selected.reader.array_nullable_enum8_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_enum16_codes(selected.column_type)
                bytes = selected.reader.array_enum16_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_enum16_codes(selected.column_type)
                bytes = selected.reader.array_nullable_enum16_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_decimal32_scale(selected.column_type)
                bytes = selected.reader.array_decimal32_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_decimal32_scale(selected.column_type)
                bytes = selected.reader.array_nullable_decimal32_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_decimal64_scale(selected.column_type)
                bytes = selected.reader.array_decimal64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_decimal64_scale(selected.column_type)
                bytes = selected.reader.array_nullable_decimal64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_decimal128_scale(selected.column_type)
                bytes = selected.reader.array_decimal128_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_decimal128_scale(selected.column_type)
                bytes = selected.reader.array_nullable_decimal128_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_decimal256_scale(selected.column_type)
                bytes = selected.reader.array_decimal256_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_decimal256_scale(selected.column_type)
                bytes = selected.reader.array_nullable_decimal256_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.uuid_array_element_type(selected.column_type)
                bytes = selected.reader.array_uuid_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_uuid_bytes[selected.name] = bytes
              elsif WidePart.nullable_uuid_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_uuid_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_uuid_bytes[selected.name] = bytes
              elsif WidePart.ipv4_array_element_type(selected.column_type)
                bytes = selected.reader.array_ipv4_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.nullable_ipv4_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_ipv4_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.ipv6_array_element_type(selected.column_type)
                bytes = selected.reader.array_ipv6_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.nullable_ipv6_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_ipv6_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.numeric_array_element_type(selected.column_type)
                bytes = selected.reader.array_numeric_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.nullable_numeric_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_numeric_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif selected.column_type == "Array(Nullable(UInt64))"
                bytes = selected.reader.array_nullable_uint64_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif selected.column_type == "Array(Array(UInt64))"
                bytes = selected.reader.array_array_uint64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_uint64_bytes[selected.name] = bytes
              elsif selected.column_type == "Array(Array(Nullable(UInt64)))"
                bytes = selected.reader.array_array_nullable_uint64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_uint64_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_temporal_element_type(selected.column_type)
                bytes = selected.reader.array_array_nullable_temporal_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_temporal_element_type(selected.column_type)
                bytes = selected.reader.array_array_temporal_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_time_element_type(selected.column_type)
                bytes = selected.reader.array_array_nullable_time_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_time_element_type(selected.column_type)
                bytes = selected.reader.array_array_time_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_decimal32_scale(selected.column_type)
                bytes = selected.reader.array_array_nullable_decimal32_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_decimal64_scale(selected.column_type)
                bytes = selected.reader.array_array_nullable_decimal64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_decimal128_scale(selected.column_type)
                bytes = selected.reader.array_array_nullable_decimal128_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_decimal256_scale(selected.column_type)
                bytes = selected.reader.array_array_nullable_decimal256_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_decimal32_scale(selected.column_type)
                bytes = selected.reader.array_array_decimal32_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_decimal64_scale(selected.column_type)
                bytes = selected.reader.array_array_decimal64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_decimal128_scale(selected.column_type)
                bytes = selected.reader.array_array_decimal128_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_decimal256_scale(selected.column_type)
                bytes = selected.reader.array_array_decimal256_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_numeric_element_type(selected.column_type)
                bytes = selected.reader.array_array_nullable_numeric_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_numeric_element_type(selected.column_type)
                bytes = selected.reader.array_array_numeric_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif selected.column_type == "Array(String)"
                bytes = selected.reader.array_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif selected.column_type == "Array(Nullable(String))"
                raw_bytes, charge_bytes = selected.reader.array_nullable_string_mark_range_preflight(selected.name, mark_index, 1)
                preflight_array_nullable_string_raw_bytes[selected.name] = raw_bytes
                preflight_array_nullable_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_tuple_uint64_string_type?(selected.column_type)
                bytes = selected.reader.tuple_uint64_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif WidePart.supports_map_uint64_string_type?(selected.column_type)
                bytes = selected.reader.map_uint64_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif WidePart.supports_map_uint64_uint64_type?(selected.column_type)
                bytes = selected.reader.map_uint64_uint64_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif WidePart.supports_map_uint64_nullable_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_uint64_nullable_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_uint64_nullable_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_uint64_nullable_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_uint64_array_nullable_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_uint64_array_nullable_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_uint64_array_nullable_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_uint64_array_nullable_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_array_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_array_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_array_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_array_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_array_nullable_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_array_nullable_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_array_nullable_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_array_nullable_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_array_nullable_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_array_nullable_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_array_nullable_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_array_nullable_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_nullable_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_nullable_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_nullable_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_nullable_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_uint64_nullable_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_uint64_nullable_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_uint64_nullable_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_uint64_nullable_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_nullable_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_nullable_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_nullable_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_nullable_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
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
            array_nullable_uint64_values = Hash(String, Array(Array(UInt64?))).new
            array_string_values = Hash(String, Array(Array(String))).new
            array_nullable_string_values = Hash(String, WidePartArrayNullableStringArray).new
            array_array_uint64_values = Hash(String, Array(Array(Array(UInt64)))).new
            array_array_string_values = Hash(String, Array(Array(Array(String)))).new
            array_array_nullable_string_values = Hash(String, WidePartArrayArrayNullableStringArray).new
            array_array_nullable_uint64_values = Hash(String, Array(Array(Array(UInt64?)))).new
            array_array_numeric_values = Hash(String, WidePartArrayArrayNumericArray).new
            array_array_nullable_numeric_values = Hash(String, WidePartArrayArrayNullableNumericArray).new
            array_numeric_values = Hash(String, WidePartArrayNumericArray).new
            array_nullable_numeric_values = Hash(String, WidePartArrayNullableNumericArray).new
            array_bool_values = Hash(String, WidePartArrayBoolArray).new
            array_nullable_bool_values = Hash(String, WidePartArrayNullableBoolArray).new
            array_tuple_uint64_string_values = Hash(String, Array(Array(Tuple(UInt64, String)))).new
            array_tuple_nullable_uint64_string_values = Hash(String, Array(Array(Tuple(UInt64?, String)))).new
            array_tuple_uint64_uint64_values = Hash(String, Array(Array(Tuple(UInt64, UInt64)))).new
            variant_string_uint64_values = Hash(String, Array(VariantStringUInt64Value)).new
            variant_bool_string_uint64_values = Hash(String, Array(VariantBoolStringUInt64Value)).new
            tuple_string_values = Hash(String, Array(Tuple(UInt64, String))).new
            map_uint64_string_values = Hash(String, Array(Array(Tuple(UInt64, String)))).new
            map_uint64_uint64_values = Hash(String, Array(Array(Tuple(UInt64, UInt64)))).new
            map_string_uint64_values = Hash(String, Array(Array(Tuple(String, UInt64)))).new
            map_string_array_uint64_values = Hash(String, Array(Array(Tuple(String, Array(UInt64))))).new
            map_string_array_nullable_uint64_values = Hash(String, Array(Array(Tuple(String, Array(UInt64?))))).new
            map_string_array_nullable_string_values = Hash(String, Array(Array(Tuple(String, Array(String?))))).new
            map_uint64_array_nullable_uint64_values = Hash(String, Array(Array(Tuple(UInt64, Array(UInt64?))))).new
            map_string_string_values = Hash(String, Array(Array(Tuple(String, String)))).new
            map_uint64_nullable_uint64_values = Hash(String, Array(Array(Tuple(UInt64, UInt64?)))).new
            map_string_nullable_uint64_values = Hash(String, Array(Array(Tuple(String, UInt64?)))).new
            map_uint64_nullable_string_values = Hash(String, Array(Array(Tuple(UInt64, String?)))).new
            map_string_nullable_string_values = Hash(String, Array(Array(Tuple(String, String?)))).new
            actual_string_bytes = 0_u64
            part.readers.each do |selected|
              if selected.column_type == "Variant(String, UInt64)"
                values = selected.reader.read_variant_string_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Variant mark row count changed") unless values.size.to_u64 == mark_rows
                expected_raw = preflight_variant_string_uint64_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Variant mark was not preflighted"))
                expected_charge = preflight_variant_string_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Variant charge was not preflighted"))
                decoded_raw = 0_u64
                values.each do |value|
                  next unless value.is_a?(String)
                  string_bytes = value.bytesize.to_u64
                  raise CorruptPartError.new("selected Variant String bytes changed after preflight") if string_bytes > expected_raw - decoded_raw
                  decoded_raw += string_bytes
                end
                raise CorruptPartError.new("selected Variant String bytes differ from preflight") unless decoded_raw == expected_raw
                row_charge = WidePart::VARIANT_STRING_UINT64_ROW_ACCOUNTING_BYTES
                raise CorruptPartError.new("selected Variant charge changed after preflight") unless mark_rows <= (UInt64::MAX - decoded_raw) // row_charge && decoded_raw + mark_rows * row_charge == expected_charge
                raise CorruptPartError.new("selected Variant mark exceeds aggregate materialization limit") if expected_charge > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += expected_charge
                variant_string_uint64_values[selected.name] = values
                next
              elsif selected.column_type == WideVariantBoolStringUInt64TypePlan::TYPE
                values = selected.reader.read_variant_bool_string_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Variant mark row count changed") unless values.size.to_u64 == mark_rows
                expected_raw = preflight_variant_bool_string_uint64_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Variant mark was not preflighted"))
                expected_charge = preflight_variant_bool_string_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Variant charge was not preflighted"))
                decoded_raw = 0_u64
                values.each do |value|
                  next unless value.is_a?(String)
                  string_bytes = value.bytesize.to_u64
                  raise CorruptPartError.new("selected Variant String bytes changed after preflight") if decoded_raw > expected_raw || string_bytes > expected_raw - decoded_raw
                  decoded_raw += string_bytes
                end
                raise CorruptPartError.new("selected Variant String bytes differ from preflight") unless decoded_raw == expected_raw
                row_charge = WidePart::VARIANT_BOOL_STRING_UINT64_ROW_ACCOUNTING_BYTES
                raise CorruptPartError.new("selected Variant charge changed after preflight") unless mark_rows <= (UInt64::MAX - decoded_raw) // row_charge && decoded_raw + mark_rows * row_charge == expected_charge
                raise CorruptPartError.new("selected Variant mark exceeds aggregate materialization limit") if expected_charge > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += expected_charge
                variant_bool_string_uint64_values[selected.name] = values
                next
              elsif WidePart.array_enum8_codes(selected.column_type)
                values = selected.reader.read_array_enum8_codes_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Enum8 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Enum8 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements
                raise CorruptPartError.new("selected Enum8 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Enum8 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_enum8_codes(selected.column_type)
                values = selected.reader.read_array_nullable_enum8_codes_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Enum8 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Enum8 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int8")
                raise CorruptPartError.new("selected nullable Enum8 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Enum8 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              elsif WidePart.array_enum16_codes(selected.column_type)
                values = selected.reader.read_array_enum16_codes_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Enum16 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Enum16 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 2_u64
                raise CorruptPartError.new("selected Enum16 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Enum16 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_enum16_codes(selected.column_type)
                values = selected.reader.read_array_nullable_enum16_codes_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Enum16 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Enum16 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int16")
                raise CorruptPartError.new("selected nullable Enum16 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Enum16 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              elsif WidePart.array_decimal32_scale(selected.column_type)
                values = selected.reader.read_array_decimal32_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal32 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal32 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 4_u64
                raise CorruptPartError.new("selected Decimal32 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal32 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_decimal32_scale(selected.column_type)
                values = selected.reader.read_array_nullable_decimal32_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal32 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal32 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int32")
                raise CorruptPartError.new("selected nullable Decimal32 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal32 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              elsif WidePart.array_decimal64_scale(selected.column_type)
                values = selected.reader.read_array_decimal64_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal64 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal64 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 8_u64
                raise CorruptPartError.new("selected Decimal64 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal64 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_decimal64_scale(selected.column_type)
                values = selected.reader.read_array_nullable_decimal64_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal64 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal64 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int64")
                raise CorruptPartError.new("selected nullable Decimal64 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal64 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              elsif WidePart.array_decimal128_scale(selected.column_type)
                values = selected.reader.read_array_decimal128_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal128 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal128 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 16_u64
                raise CorruptPartError.new("selected Decimal128 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal128 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_decimal128_scale(selected.column_type)
                values = selected.reader.read_array_nullable_decimal128_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal128 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal128 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int128")
                raise CorruptPartError.new("selected nullable Decimal128 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal128 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              elsif WidePart.array_decimal256_scale(selected.column_type)
                values = selected.reader.read_array_decimal256_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal256 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal256 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 32_u64
                raise CorruptPartError.new("selected Decimal256 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal256 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_decimal256_scale(selected.column_type)
                values = selected.reader.read_array_nullable_decimal256_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal256 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal256 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Decimal256")
                raise CorruptPartError.new("selected nullable Decimal256 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal256 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              end

              if plan = WideTypePlan.admitted(selected.column_type)
                case plan.shape
                when WideTypePlan::Shape::ArrayArrayString
                  values = selected.reader.read_array_array_string_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected Array(Array(String)) mark row count changed") unless values.size.to_u64 == mark_rows
                  preflight_bytes = preflight_array_array_string_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(String)) mark was not preflighted"))
                  decoded_bytes = array_array_string_materialized_bytes(values)
                  raise CorruptPartError.new("selected Array(Array(String)) decoded bytes differ from preflight") unless decoded_bytes == preflight_bytes
                  raise CorruptPartError.new("selected Array(Array(String)) mark exceeds aggregate materialization limit") if decoded_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += decoded_bytes
                  array_array_string_values[selected.name] = values
                when WideTypePlan::Shape::ArrayArrayNullableString
                  values = selected.reader.read_array_array_nullable_string_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected Array(Array(Nullable(String))) mark row count changed") unless values.size.to_u64 == mark_rows
                  preflight_bytes = preflight_array_array_nullable_string_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(Nullable(String))) mark was not preflighted"))
                  decoded_bytes = array_array_nullable_string_materialized_bytes(values)
                  raise CorruptPartError.new("selected Array(Array(Nullable(String))) decoded bytes exceed preflight") if decoded_bytes > preflight_bytes
                  raise CorruptPartError.new("selected Array(Array(Nullable(String))) mark exceeds aggregate materialization limit") if preflight_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += preflight_bytes
                  array_array_nullable_string_values[selected.name] = values
                when WideTypePlan::Shape::ArrayTupleUInt64String
                  preflight_bytes = preflight_array_tuple_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Tuple) mark was not preflighted"))
                  values = selected.reader.read_array_tuple_uint64_string_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected Array(Tuple) mark row count changed") unless values.size.to_u64 == mark_rows
                  decoded_bytes = array_tuple_materialized_bytes(values, 16_u64)
                  raise CorruptPartError.new("selected Array(Tuple) decoded bytes differ from preflight") unless decoded_bytes == preflight_bytes
                  raise CorruptPartError.new("selected Array(Tuple) mark exceeds aggregate materialization limit") if decoded_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += decoded_bytes
                  array_tuple_uint64_string_values[selected.name] = values
                when WideTypePlan::Shape::ArrayTupleNullableUInt64String
                  preflight_bytes = preflight_array_tuple_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Tuple) mark was not preflighted"))
                  values = selected.reader.read_array_tuple_nullable_uint64_string_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected nullable Array(Tuple) mark row count changed") unless values.size.to_u64 == mark_rows
                  decoded_bytes = array_tuple_materialized_bytes(values, 17_u64)
                  raise CorruptPartError.new("selected nullable Array(Tuple) decoded bytes differ from preflight") unless decoded_bytes == preflight_bytes
                  raise CorruptPartError.new("selected nullable Array(Tuple) mark exceeds aggregate materialization limit") if decoded_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += decoded_bytes
                  array_tuple_nullable_uint64_string_values[selected.name] = values
                when WideTypePlan::Shape::ArrayTupleUInt64UInt64
                  preflight_bytes = preflight_array_tuple_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Tuple) mark was not preflighted"))
                  values = selected.reader.read_array_tuple_uint64_uint64_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected Array(Tuple) mark row count changed") unless values.size.to_u64 == mark_rows
                  decoded_bytes = array_tuple_uint64_uint64_materialized_bytes(values)
                  raise CorruptPartError.new("selected Array(Tuple) decoded bytes differ from preflight") unless decoded_bytes == preflight_bytes
                  raise CorruptPartError.new("selected Array(Tuple) mark exceeds aggregate materialization limit") if decoded_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += decoded_bytes
                  array_tuple_uint64_uint64_values[selected.name] = values
                end
                next
              end

              case selected.column_type
              when "Array(UUID)"
                values = selected.reader.read_array_uuids_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(UUID) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_uuid_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(UUID) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 16_u64
                raise CorruptPartError.new("selected Array(UUID) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(UUID) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when "Array(Nullable(UUID))"
                values = selected.reader.read_array_nullable_uuids_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(UUID)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_uuid_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(UUID)) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 17_u64
                raise CorruptPartError.new("selected Array(Nullable(UUID)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(UUID)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when "Array(IPv4)"
                values = selected.reader.read_array_ipv4s_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(IPv4) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(IPv4) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 4_u64
                raise CorruptPartError.new("selected Array(IPv4) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(IPv4) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when "Array(Nullable(IPv4))"
                values = selected.reader.read_array_nullable_ipv4s_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(IPv4)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(IPv4)) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 5_u64
                raise CorruptPartError.new("selected Array(Nullable(IPv4)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(IPv4)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when "Array(IPv6)"
                values = selected.reader.read_array_ipv6s_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(IPv6) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(IPv6) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 16_u64
                raise CorruptPartError.new("selected Array(IPv6) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(IPv6) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when "Array(Nullable(IPv6))"
                values = selected.reader.read_array_nullable_ipv6s_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(IPv6)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(IPv6)) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 17_u64
                raise CorruptPartError.new("selected Array(Nullable(IPv6)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(IPv6)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when "Array(Date)", "Array(Date32)", "Array(DateTime)"
                element_type = WidePart.temporal_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported temporal Array type"))
                values = read_array_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected temporal Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected temporal Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                bytes = elements * WidePart.array_numeric_payload_width(physical_type).to_u64
                raise CorruptPartError.new("selected temporal Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected temporal Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when "Array(Time)"
                values = selected.reader.read_array_time_seconds_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Time Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Time Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 4_u64
                raise CorruptPartError.new("selected Time Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Time Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when .starts_with?("Array(Time64(")
                raise UnsupportedFormatError.new("unsupported exact Time64 Array type") unless WidePart.array_time64_scale(selected.column_type)
                values = selected.reader.read_array_time64_ticks_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Time64 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Time64 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 8_u64
                raise CorruptPartError.new("selected Time64 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Time64 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when .starts_with?("Array(DateTime64(")
                element_type = WidePart.temporal_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported temporal Array type"))
                values = read_array_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected temporal Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected temporal Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                bytes = elements * WidePart.array_numeric_payload_width(physical_type).to_u64
                raise CorruptPartError.new("selected temporal Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected temporal Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
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
              when "Array(UInt8)", "Array(UInt16)", "Array(UInt32)", "Array(UInt64)",
                   "Array(Int8)", "Array(Int16)", "Array(Int32)", "Array(Int64)",
                   "Array(Float32)", "Array(Float64)",
                   "Array(Int128)", "Array(UInt128)", "Array(Int256)", "Array(UInt256)",
                   "Array(BFloat16)"
                element_type = WidePart.numeric_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported Array numeric type"))
                values = read_array_numeric_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected Array numeric mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array numeric mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * WidePart.array_numeric_payload_width(element_type).to_u64
                raise CorruptPartError.new("selected Array numeric decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array numeric mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                array_uint64_values[selected.name] = values.as(Array(Array(UInt64))) if selected.column_type == "Array(UInt64)"
              when "Array(Bool)"
                values = selected.reader.read_array_bool_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Bool) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_bool_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Bool) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                raise CorruptPartError.new("selected Array(Bool) decoded bytes differ from preflight") unless elements == preflight_bytes
                raise CorruptPartError.new("selected Array(Bool) mark exceeds aggregate materialization limit") if elements > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += elements
                array_bool_values[selected.name] = values
              when "Array(Nullable(String))"
                values, raw_bytes = selected.reader.read_array_nullable_string_mark_range_with_raw_bytes(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(String)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_raw_bytes = preflight_array_nullable_string_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(String)) mark was not preflighted"))
                raise CorruptPartError.new("selected Array(Nullable(String)) decoded raw bytes differ from preflight") unless raw_bytes == preflight_raw_bytes
                visible_bytes, materialized_bytes = array_nullable_string_materialized_bytes(values)
                raise CorruptPartError.new("selected Array(Nullable(String)) visible bytes exceed preflight raw bytes") if visible_bytes > raw_bytes
                preflight_charge_bytes = preflight_array_nullable_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(String)) charge was not preflighted"))
                raise CorruptPartError.new("selected Array(Nullable(String)) decoded charge exceeds preflight") if materialized_bytes > preflight_charge_bytes
                raise CorruptPartError.new("selected Array(Nullable(String)) mark exceeds aggregate materialization limit") if materialized_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += materialized_bytes
                array_nullable_string_values[selected.name] = values
              when .starts_with?("Array(Nullable(FixedString(")
                width = WidePart.array_nullable_fixed_string_width(selected.column_type) || raise(UnsupportedFormatError.new("unsupported exact Array(Nullable(FixedString(N))) type"))
                values = selected.reader.read_array_nullable_fixed_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(FixedString(N))) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_raw_bytes = preflight_array_fixed_string_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(FixedString(N))) mark was not preflighted"))
                elements = checked_array_fixed_string_elements(values, width)
                raw_bytes = elements * (width.to_u64 + 1_u64)
                raise CorruptPartError.new("selected Array(Nullable(FixedString(N))) decoded bytes differ from preflight") unless raw_bytes == preflight_raw_bytes
                bytes = array_fixed_string_charge_bytes(raw_bytes, width, mark_rows, true)
                raise CorruptPartError.new("selected Array(Nullable(FixedString(N))) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_string_values[selected.name] = values
              when "Array(Nullable(Bool))"
                values = selected.reader.read_array_nullable_bool_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(Bool)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_bool_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(Bool)) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 2_u64
                raise CorruptPartError.new("selected Array(Nullable(Bool)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(Bool)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_bool_values[selected.name] = values
              when "Array(Nullable(Date))", "Array(Nullable(Date32))", "Array(Nullable(DateTime))"
                element_type = WidePart.nullable_temporal_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nullable temporal Array type"))
                values = read_array_nullable_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected nullable temporal Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable temporal Array mark was not preflighted"))
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                bytes = array_nullable_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected nullable temporal Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable temporal Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when "Array(Nullable(Time))"
                values = selected.reader.read_array_nullable_time_seconds_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(Time)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(Time)) mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int32")
                raise CorruptPartError.new("selected Array(Nullable(Time)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(Time)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Nullable(Time64(")
                raise UnsupportedFormatError.new("unsupported exact Array(Nullable(Time64(p))) type") unless WidePart.nullable_array_time64_scale(selected.column_type)
                values = selected.reader.read_array_nullable_time64_ticks_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(Time64(p))) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(Time64(p))) mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int64")
                raise CorruptPartError.new("selected Array(Nullable(Time64(p))) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(Time64(p))) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Nullable(DateTime64(")
                element_type = WidePart.nullable_temporal_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nullable temporal Array type"))
                values = read_array_nullable_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected nullable temporal Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable temporal Array mark was not preflighted"))
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                bytes = array_nullable_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected nullable temporal Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable temporal Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Nullable(")
                element_type = WidePart.nullable_numeric_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported Array nullable numeric type"))
                values = read_array_nullable_numeric_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected Array(Nullable(T)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(T)) mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, element_type)
                raise CorruptPartError.new("selected Array(Nullable(T)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(T)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                array_nullable_uint64_values[selected.name] = values.as(Array(Array(UInt64?))) if element_type == "UInt64"
              when "Array(Nullable(UInt64))"
                values = selected.reader.read_array_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(UInt64)) mark row count changed") unless values.size.to_u64 == mark_rows
                elements = 0_u64
                values.each do |row|
                  row_elements = row.size.to_u64
                  if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
                    raise CorruptPartError.new("selected Array(Nullable(UInt64)) mark element count exceeds materialization limit")
                  end
                  elements += row_elements
                end
                bytes = elements * 9_u64
                raise CorruptPartError.new("selected Array(Nullable(UInt64)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_uint64_values[selected.name] = values
              when "Array(Array(UInt64))"
                values = selected.reader.read_array_array_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Array(UInt64)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_uint64_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(UInt64)) mark was not preflighted"))
                bytes = array_array_uint64_materialized_bytes(values)
                raise CorruptPartError.new("selected Array(Array(UInt64)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Array(UInt64)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_uint64_values[selected.name] = values
                array_array_numeric_values[selected.name] = values.as(WidePartArrayArrayNumericArray)
              when "Array(Array(Nullable(UInt64)))"
                values = selected.reader.read_array_array_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_uint64_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(Nullable(UInt64))) mark was not preflighted"))
                bytes = array_array_nullable_uint64_materialized_bytes(values)
                raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_uint64_values[selected.name] = values
                array_array_nullable_numeric_values[selected.name] = values.as(WidePartArrayArrayNullableNumericArray)
              when .starts_with?("Array(Array(Nullable(Time")
                element_type = WidePart.array_array_nullable_time_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nested nullable Time declaration"))
                physical_type = WidePart.time_array_physical_type(element_type).not_nil!
                values = read_array_array_nullable_time_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected nullable Time nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Time nested Array mark was not preflighted"))
                bytes = array_array_nullable_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected nullable Time nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Time nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Time")
                element_type = WidePart.array_array_time_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nested Time declaration"))
                physical_type = WidePart.time_array_physical_type(element_type).not_nil!
                values = read_array_array_time_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected Time nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Time nested Array mark was not preflighted"))
                bytes = array_array_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected Time nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Time nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Nullable(Date")
                element_type = WidePart.array_array_nullable_temporal_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nested nullable temporal declaration"))
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                values = read_array_array_nullable_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected nullable temporal nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable temporal nested Array mark was not preflighted"))
                bytes = array_array_nullable_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected nullable temporal nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable temporal nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Date")
                element_type = WidePart.array_array_temporal_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nested temporal declaration"))
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                values = read_array_array_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected temporal nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected temporal nested Array mark was not preflighted"))
                bytes = array_array_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected temporal nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected temporal nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Nullable(Decimal(9,")
                raise UnsupportedFormatError.new("unsupported nested nullable Decimal32 declaration") unless WidePart.array_array_nullable_decimal32_scale(selected.column_type)
                values = selected.reader.read_array_array_nullable_decimal32_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal32 nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal32 nested Array mark was not preflighted"))
                bytes = array_array_nullable_numeric_materialized_bytes(values, "Int32")
                raise CorruptPartError.new("selected nullable Decimal32 nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal32 nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Nullable(Decimal(18,")
                raise UnsupportedFormatError.new("unsupported nested nullable Decimal64 declaration") unless WidePart.array_array_nullable_decimal64_scale(selected.column_type)
                values = selected.reader.read_array_array_nullable_decimal64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal64 nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal64 nested Array mark was not preflighted"))
                bytes = array_array_nullable_numeric_materialized_bytes(values, "Int64")
                raise CorruptPartError.new("selected nullable Decimal64 nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal64 nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Nullable(Decimal(38,")
                raise UnsupportedFormatError.new("unsupported nested nullable Decimal128 declaration") unless WidePart.array_array_nullable_decimal128_scale(selected.column_type)
                values = selected.reader.read_array_array_nullable_decimal128_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal128 nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal128 nested Array mark was not preflighted"))
                bytes = array_array_nullable_numeric_materialized_bytes(values, "Int128")
                raise CorruptPartError.new("selected nullable Decimal128 nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal128 nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Nullable(Decimal(76,")
                raise UnsupportedFormatError.new("unsupported nested nullable Decimal256 declaration") unless WidePart.array_array_nullable_decimal256_scale(selected.column_type)
                values = selected.reader.read_array_array_nullable_decimal256_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal256 nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal256 nested Array mark was not preflighted"))
                bytes = array_array_nullable_numeric_materialized_bytes(values, "Decimal256")
                raise CorruptPartError.new("selected nullable Decimal256 nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal256 nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Decimal(9,")
                raise UnsupportedFormatError.new("unsupported nested Decimal32 declaration") unless WidePart.array_array_decimal32_scale(selected.column_type)
                values = selected.reader.read_array_array_decimal32_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal32 nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal32 nested Array mark was not preflighted"))
                bytes = array_array_numeric_materialized_bytes(values, "Int32")
                raise CorruptPartError.new("selected Decimal32 nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal32 nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Decimal(18,")
                raise UnsupportedFormatError.new("unsupported nested Decimal64 declaration") unless WidePart.array_array_decimal64_scale(selected.column_type)
                values = selected.reader.read_array_array_decimal64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal64 nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal64 nested Array mark was not preflighted"))
                bytes = array_array_numeric_materialized_bytes(values, "Int64")
                raise CorruptPartError.new("selected Decimal64 nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal64 nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Decimal(38,")
                raise UnsupportedFormatError.new("unsupported nested Decimal128 declaration") unless WidePart.array_array_decimal128_scale(selected.column_type)
                values = selected.reader.read_array_array_decimal128_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal128 nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal128 nested Array mark was not preflighted"))
                bytes = array_array_numeric_materialized_bytes(values, "Int128")
                raise CorruptPartError.new("selected Decimal128 nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal128 nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Decimal(76,")
                raise UnsupportedFormatError.new("unsupported nested Decimal256 declaration") unless WidePart.array_array_decimal256_scale(selected.column_type)
                values = selected.reader.read_array_array_decimal256_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal256 nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal256 nested Array mark was not preflighted"))
                bytes = array_array_numeric_materialized_bytes(values, "Decimal256")
                raise CorruptPartError.new("selected Decimal256 nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal256 nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Nullable(")
                element_type = WidePart.array_array_nullable_numeric_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported Array(Array(Nullable(T))) numeric type"))
                values = read_array_array_nullable_numeric_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected Array(Array(Nullable(T))) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(Nullable(T))) mark was not preflighted"))
                bytes = array_array_nullable_numeric_materialized_bytes(values, element_type)
                raise CorruptPartError.new("selected Array(Array(Nullable(T))) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Array(Nullable(T))) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(")
                element_type = WidePart.array_array_numeric_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported Array(Array(T)) numeric type"))
                values = read_array_array_numeric_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected Array(Array(T)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(T)) mark was not preflighted"))
                bytes = array_array_numeric_materialized_bytes(values, element_type)
                raise CorruptPartError.new("selected Array(Array(T)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Array(T)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when "Array(String)"
                values = selected.reader.read_array_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(String) mark row count changed") unless values.size.to_u64 == mark_rows
                bytes = values.sum { |row| row.sum(&.bytesize) }.to_u64
                raise CorruptPartError.new("selected array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_string_values[selected.name] = values
              when .starts_with?("Array(FixedString(")
                width = WidePart.array_fixed_string_width(selected.column_type) || raise(UnsupportedFormatError.new("unsupported exact Array(FixedString(N)) type"))
                values = selected.reader.read_array_fixed_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(FixedString(N)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_raw_bytes = preflight_array_fixed_string_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(FixedString(N)) mark was not preflighted"))
                elements = checked_array_fixed_string_elements(values, width)
                raw_bytes = elements * width.to_u64
                raise CorruptPartError.new("selected Array(FixedString(N)) decoded bytes differ from preflight") unless raw_bytes == preflight_raw_bytes
                bytes = array_fixed_string_charge_bytes(raw_bytes, width, mark_rows, false)
                raise CorruptPartError.new("selected Array(FixedString(N)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_string_values[selected.name] = values
              when "Tuple(a UInt64, b String)"
                values = selected.reader.read_tuple_uint64_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Tuple mark row count changed") unless values.size.to_u64 == mark_rows
                values.each do |_number, string_value|
                  bytes = string_value.bytesize.to_u64
                  raise CorruptPartError.new("selected Tuple mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += bytes
                end
                tuple_string_values[selected.name] = values
              when "Map(UInt64, String)"
                values = selected.reader.read_map_uint64_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                bytes = values.sum { |row| row.sum { |_key, value| value.bytesize } }.to_u64
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                map_uint64_string_values[selected.name] = values
              when "Map(UInt64, UInt64)"
                values = selected.reader.read_map_uint64_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = values.sum { |row| row.size }.to_u64
                bytes = entries * 16_u64
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                map_uint64_uint64_values[selected.name] = values
              when "Map(UInt64, Nullable(UInt64))"
                values = selected.reader.read_map_uint64_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                end
                if entries > UInt64::MAX // 17_u64
                  raise CorruptPartError.new("selected Map key/value payload overflows")
                end
                payload_bytes = entries * 17_u64
                expected_payload_bytes = preflight_map_uint64_nullable_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/null/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_uint64_nullable_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_uint64_nullable_uint64_values[selected.name] = values
              when "Map(String, UInt64)"
                values = selected.reader.read_map_string_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                key_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, _value|
                    bytes = key.bytesize.to_u64
                    raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                    key_bytes += bytes
                  end
                end
                value_bytes = entries * 8_u64
                if value_bytes > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/value payload overflows")
                end
                payload_bytes = key_bytes + value_bytes
                expected_payload_bytes = preflight_map_string_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_string_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                bytes = charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                map_string_uint64_values[selected.name] = values
              when "Map(String, Array(UInt64))"
                values = selected.reader.read_map_string_array_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                nested_elements = 0_u64
                key_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, array_values|
                    bytes = key.bytesize.to_u64
                    raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                    key_bytes += bytes
                    if array_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - nested_elements
                      raise CorruptPartError.new("selected Map nested Array element count exceeds materialization limit")
                    end
                    nested_elements += array_values.size.to_u64
                  end
                end
                if nested_elements > UInt64::MAX // 8_u64
                  raise CorruptPartError.new("selected Map nested Array byte count overflows")
                end
                value_bytes = nested_elements * 8_u64
                if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64
                  raise CorruptPartError.new("selected Map nested Array bytes exceed materialization limit")
                end
                if value_bytes > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/value payload overflows")
                end
                payload_bytes = key_bytes + value_bytes
                expected_payload_bytes = preflight_map_string_array_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_string_array_uint64_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_string_array_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_array_uint64_values[selected.name] = values
              when "Map(String, Array(Nullable(UInt64)))"
                values = selected.reader.read_map_string_array_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                nested_elements = 0_u64
                key_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, array_values|
                    bytes = key.bytesize.to_u64
                    raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                    key_bytes += bytes
                    if array_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - nested_elements
                      raise CorruptPartError.new("selected Map nested Array element count exceeds materialization limit")
                    end
                    nested_elements += array_values.size.to_u64
                  end
                end
                if nested_elements > UInt64::MAX // 9_u64
                  raise CorruptPartError.new("selected Map nested nullable Array byte count overflows")
                end
                # Each nested Nullable(UInt64) element retains a null byte and
                # an eight-byte child slot, including hidden slots under NULL.
                value_bytes = nested_elements * 9_u64
                if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64
                  raise CorruptPartError.new("selected Map nested nullable Array bytes exceed materialization limit")
                end
                if value_bytes > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                payload_bytes = key_bytes + value_bytes
                expected_payload_bytes = preflight_map_string_array_nullable_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/null/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                # W68 has the same row/entry/Array-container accounting as
                # W63; its payload includes the nullable physical child bytes.
                charge_bytes = checked_map_string_array_uint64_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_string_array_nullable_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_array_nullable_uint64_values[selected.name] = values
              when "Map(String, Array(Nullable(String)))"
                values = selected.reader.read_map_string_array_nullable_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                leaves = 0_u64
                visible_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, array_values|
                    key_bytes = key.bytesize.to_u64
                    raise CorruptPartError.new("selected Map visible String bytes exceed preflight") if key_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_bytes
                    visible_bytes += key_bytes
                    if array_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaves
                      raise CorruptPartError.new("selected Map nested String leaf count exceeds materialization limit")
                    end
                    leaves += array_values.size.to_u64
                    array_values.each do |value|
                      next unless value
                      value_bytes = value.not_nil!.bytesize.to_u64
                      raise CorruptPartError.new("selected Map visible String bytes exceed preflight") if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_bytes
                      visible_bytes += value_bytes
                    end
                  end
                end
                expected_payload_bytes = preflight_map_string_array_nullable_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map visible String bytes exceed physical preflight") if visible_bytes > expected_payload_bytes
                charge_bytes = preflight_map_string_array_nullable_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map charge is smaller than its physical payload") if charge_bytes < expected_payload_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_array_nullable_string_values[selected.name] = values
              when "Map(UInt64, Array(Nullable(UInt64)))"
                values = selected.reader.read_map_uint64_array_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                nested_elements = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |_key, array_values|
                    if array_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - nested_elements
                      raise CorruptPartError.new("selected Map nested Array element count exceeds materialization limit")
                    end
                    nested_elements += array_values.size.to_u64
                  end
                end
                if entries > UInt64::MAX // 8_u64 || nested_elements > UInt64::MAX // 9_u64
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                key_bytes = entries * 8_u64
                # Every Nullable(UInt64) slot includes one null-map byte and
                # the eight-byte child slot, even when the value is NULL.
                nested_bytes = nested_elements * 9_u64
                if nested_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64
                  raise CorruptPartError.new("selected Map nested nullable Array bytes exceed materialization limit")
                end
                if nested_bytes > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                payload_bytes = key_bytes + nested_bytes
                expected_payload_bytes = preflight_map_uint64_array_nullable_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/null/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_string_array_uint64_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_uint64_array_nullable_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_uint64_array_nullable_uint64_values[selected.name] = values
              when "Map(String, String)"
                values = selected.reader.read_map_string_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                payload_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, value|
                    key_bytes = key.bytesize.to_u64
                    value_bytes = value.bytesize.to_u64
                    if key_bytes > UInt64::MAX - payload_bytes || value_bytes > UInt64::MAX - payload_bytes - key_bytes
                      raise CorruptPartError.new("selected Map key/value payload overflows")
                    end
                    payload_bytes += key_bytes + value_bytes
                  end
                end
                expected_payload_bytes = preflight_map_string_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_string_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                bytes = charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                map_string_string_values[selected.name] = values
              when "Map(String, Nullable(UInt64))"
                values = selected.reader.read_map_string_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                key_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, _value|
                    bytes = key.bytesize.to_u64
                    raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                    key_bytes += bytes
                  end
                end
                if entries > UInt64::MAX // 9_u64 || entries * 9_u64 > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                payload_bytes = key_bytes + entries * 9_u64
                expected_payload_bytes = preflight_map_string_nullable_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/null/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_string_nullable_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_nullable_uint64_values[selected.name] = values
              when "Map(UInt64, Nullable(String))"
                values = selected.reader.read_map_uint64_nullable_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                visible_value_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |_key, value|
                    next unless value
                    value_bytes = value.not_nil!.bytesize.to_u64
                    if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_value_bytes
                      raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit")
                    end
                    visible_value_bytes += value_bytes
                  end
                end
                metadata_bytes = entries * 17_u64
                if metadata_bytes > UInt64::MAX - visible_value_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                payload_bytes = metadata_bytes + visible_value_bytes
                expected_payload_bytes = preflight_map_uint64_nullable_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map decoded value payload exceeds preflight") if payload_bytes > expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, expected_payload_bytes)
                expected_charge_bytes = preflight_map_uint64_nullable_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_uint64_nullable_string_values[selected.name] = values
              when "Map(String, Nullable(String))"
                values = selected.reader.read_map_string_nullable_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                key_bytes = 0_u64
                visible_value_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, value|
                    bytes = key.bytesize.to_u64
                    if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                      raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit")
                    end
                    key_bytes += bytes
                    next unless value
                    value_bytes = value.not_nil!.bytesize.to_u64
                    if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_value_bytes
                      raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit")
                    end
                    visible_value_bytes += value_bytes
                  end
                end
                if entries > UInt64::MAX // 17_u64 || entries * 17_u64 > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                metadata_bytes = key_bytes + entries * 17_u64
                if visible_value_bytes > UInt64::MAX - metadata_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                payload_bytes = metadata_bytes + visible_value_bytes
                expected_payload_bytes = preflight_map_string_nullable_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map decoded value payload exceeds preflight") if payload_bytes > expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, expected_payload_bytes)
                expected_charge_bytes = preflight_map_string_nullable_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_nullable_string_values[selected.name] = values
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
              array_nullable_uint64_slices = Hash(String, Slice(Array(UInt64?))).new
              array_string_slices = Hash(String, Slice(Array(String))).new
              array_array_uint64_slices = Hash(String, Slice(Array(Array(UInt64)))).new
              array_array_string_slices = Hash(String, Slice(Array(Array(String)))).new
              array_array_nullable_string_slices = Hash(String, WidePartArrayArrayNullableStringSlice).new
              array_array_nullable_uint64_slices = Hash(String, Slice(Array(Array(UInt64?)))).new
              array_array_numeric_slices = Hash(String, WidePartArrayArrayNumericSlice).new
              array_array_nullable_numeric_slices = Hash(String, WidePartArrayArrayNullableNumericSlice).new
              array_numeric_slices = Hash(String, WidePartArrayNumericSlice).new
              array_nullable_numeric_slices = Hash(String, WidePartArrayNullableNumericSlice).new
              array_bool_slices = Hash(String, WidePartArrayBoolSlice).new
              array_nullable_bool_slices = Hash(String, WidePartArrayNullableBoolSlice).new
              array_tuple_uint64_string_slices = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
              array_tuple_nullable_uint64_string_slices = Hash(String, Slice(Array(Tuple(UInt64?, String)))).new
              array_tuple_uint64_uint64_slices = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
              variant_string_uint64_slices = Hash(String, Slice(VariantStringUInt64Value)).new
              variant_bool_string_uint64_slices = Hash(String, Slice(VariantBoolStringUInt64Value)).new
              array_nullable_string_slices = Hash(String, WidePartArrayNullableStringSlice).new
              tuple_string_slices = Hash(String, Slice(Tuple(UInt64, String))).new
              map_uint64_string_slices = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
              map_uint64_uint64_slices = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
              map_string_uint64_slices = Hash(String, Slice(Array(Tuple(String, UInt64)))).new
              map_string_array_uint64_slices = Hash(String, Slice(Array(Tuple(String, Array(UInt64))))).new
              map_string_array_nullable_uint64_slices = Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))).new
              map_string_array_nullable_string_slices = Hash(String, Slice(Array(Tuple(String, Array(String?))))).new
              map_uint64_array_nullable_uint64_slices = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))).new
              map_string_string_slices = Hash(String, Slice(Array(Tuple(String, String)))).new
              map_uint64_nullable_uint64_slices = Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))).new
              map_string_nullable_uint64_slices = Hash(String, Slice(Array(Tuple(String, UInt64?)))).new
              map_uint64_nullable_string_slices = Hash(String, Slice(Array(Tuple(UInt64, String?)))).new
              map_string_nullable_string_slices = Hash(String, Slice(Array(Tuple(String, String?)))).new
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
                elsif values = array_numeric_values[selected.name]?
                  selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                  array_numeric_slices[selected.name] = selected_slice.as(WidePartArrayNumericSlice)
                  if selected.column_type == "Array(UInt64)"
                    array_uint64_slices[selected.name] = selected_slice.as(Slice(Array(UInt64)))
                  end
                elsif values = array_nullable_numeric_values[selected.name]?
                  selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                  array_nullable_numeric_slices[selected.name] = selected_slice.as(WidePartArrayNullableNumericSlice)
                  if selected.column_type == "Array(Nullable(UInt64))"
                    array_nullable_uint64_slices[selected.name] = selected_slice.as(Slice(Array(UInt64?)))
                  end
                elsif values = array_bool_values[selected.name]?
                  array_bool_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_nullable_bool_values[selected.name]?
                  array_nullable_bool_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_uint64_values[selected.name]?
                  array_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_nullable_uint64_values[selected.name]?
                  array_nullable_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_array_uint64_values[selected.name]?
                  selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                  array_array_uint64_slices[selected.name] = selected_slice
                  array_array_numeric_slices[selected.name] = selected_slice.as(WidePartArrayArrayNumericSlice)
                elsif values = array_array_string_values[selected.name]?
                  array_array_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_array_nullable_string_values[selected.name]?
                  array_array_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_array_nullable_uint64_values[selected.name]?
                  selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                  array_array_nullable_uint64_slices[selected.name] = selected_slice
                  array_array_nullable_numeric_slices[selected.name] = selected_slice.as(WidePartArrayArrayNullableNumericSlice)
                elsif values = array_array_nullable_numeric_values[selected.name]?
                  array_array_nullable_numeric_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size].as(WidePartArrayArrayNullableNumericSlice)
                elsif values = array_array_numeric_values[selected.name]?
                  array_array_numeric_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size].as(WidePartArrayArrayNumericSlice)
                elsif values = array_string_values[selected.name]?
                  array_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_nullable_string_values[selected.name]?
                  array_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_tuple_uint64_string_values[selected.name]?
                  array_tuple_uint64_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_tuple_nullable_uint64_string_values[selected.name]?
                  array_tuple_nullable_uint64_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_tuple_uint64_uint64_values[selected.name]?
                  array_tuple_uint64_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = variant_string_uint64_values[selected.name]?
                  variant_string_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = variant_bool_string_uint64_values[selected.name]?
                  variant_bool_string_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = tuple_string_values[selected.name]?
                  tuple_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_string_values[selected.name]?
                  map_uint64_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_uint64_values[selected.name]?
                  map_uint64_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_uint64_values[selected.name]?
                  map_string_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_array_uint64_values[selected.name]?
                  map_string_array_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_array_nullable_uint64_values[selected.name]?
                  map_string_array_nullable_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_array_nullable_string_values[selected.name]?
                  map_string_array_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_array_nullable_uint64_values[selected.name]?
                  map_uint64_array_nullable_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_string_values[selected.name]?
                  map_string_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_nullable_uint64_values[selected.name]?
                  map_uint64_nullable_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_nullable_uint64_values[selected.name]?
                  map_string_nullable_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_nullable_string_values[selected.name]?
                  map_uint64_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_nullable_string_values[selected.name]?
                  map_string_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
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
                array_string_slices,
                tuple_string_slices,
                map_uint64_string_slices,
                map_uint64_uint64_slices,
                array_nullable_uint64_slices,
                array_array_uint64_slices,
                array_array_nullable_uint64_slices,
                array_array_numeric_slices,
                array_array_nullable_numeric_slices,
                array_numeric_slices,
                array_nullable_numeric_slices,
                array_nullable_string_slices,
                array_bool_slices,
                array_nullable_bool_slices,
                array_tuple_uint64_string_slices,
                array_tuple_nullable_uint64_string_slices,
                map_string_uint64_slices,
                map_string_string_slices,
                map_uint64_nullable_uint64_slices,
                map_string_nullable_uint64_slices,
                map_uint64_nullable_string_slices,
                map_string_nullable_string_slices,
                array_tuple_uint64_uint64_slices,
                variant_string_uint64_slices,
                variant_bool_string_uint64_slices,
                array_array_string_slices,
                array_array_nullable_string_slices,
                map_string_array_uint64_slices,
                map_string_array_nullable_uint64_slices,
                map_uint64_array_nullable_uint64_slices,
                map_string_array_nullable_string_values: map_string_array_nullable_string_slices
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
      elsif type == "BFloat16"
        return reader.read_bfloat16_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum8_codes(type).nil? && !type.starts_with?("Nullable(")
        return reader.read_enum8_codes_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum16_codes(type).nil? && !type.starts_with?("Nullable(")
        return reader.read_enum16_codes_mark_range(selected.name, mark_index, 1)
      elsif type == "Int128"
        return reader.read_int128_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "UInt128"
        return reader.read_uint128_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "Int256"
        return reader.read_int256_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "UInt256"
        return reader.read_uint256_raw_mark_range(selected.name, mark_index, 1)
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
      when "Time"
        reader.read_time_seconds_mark_range(selected.name, mark_index, 1)
      when .starts_with?("DateTime64(")
        unless WidePart.datetime64_scale(selected.column_type)
          raise UnsupportedFormatError.new("unsupported exact DateTime64 type")
        end
        reader.read_datetime64_ticks_mark_range(selected.name, mark_index, 1)
      when .starts_with?("Time64(")
        unless WidePart.time64_scale(selected.column_type)
          raise UnsupportedFormatError.new("unsupported exact Time64 type")
        end
        reader.read_time64_ticks_mark_range(selected.name, mark_index, 1)
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

    private def read_array_numeric_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayNumericArray
      case element_type
      when "UInt8"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt64)
      when "Int8"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int8)
      when "Int16"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int16)
      when "Int32"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int32)
      when "Int64"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int64)
      when "Int128"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int128)
      when "UInt128"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt128)
      when "Int256"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int256Value)
      when "UInt256"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt256Value)
      when "Float32"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Float32)
      when "Float64"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Float64)
      when "BFloat16"
        reader.read_array_numeric_mark_range(column, mark_index, 1, BFloat16Value)
      else
        raise UnsupportedFormatError.new("unsupported Array numeric leaf type")
      end
    end

    private def read_array_array_numeric_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNumericArray
      case element_type
      when "UInt8"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt64)
      when "Int8"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int8)
      when "Int16"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int16)
      when "Int32"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int32)
      when "Int64"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int64)
      when "Float32"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Float32)
      when "Float64"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Float64)
      when "Int128"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int128)
      when "UInt128"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt128)
      when "Int256"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int256Value)
      when "UInt256"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt256Value)
      when "BFloat16"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, BFloat16Value)
      else
        raise UnsupportedFormatError.new("unsupported Array(Array(T)) numeric leaf type")
      end
    end

    private def read_array_array_nullable_numeric_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNullableNumericArray
      case element_type
      when "UInt8"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt64)
      when "Int8"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int8)
      when "Int16"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int16)
      when "Int32"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int32)
      when "Int64"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int64)
      when "Float32"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Float32)
      when "Float64"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Float64)
      when "Int128"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int128)
      when "UInt128"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt128)
      when "Int256"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int256Value)
      when "UInt256"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt256Value)
      when "BFloat16"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, BFloat16Value)
      else
        raise UnsupportedFormatError.new("unsupported Array(Array(Nullable(T))) numeric leaf type")
      end
    end

    private def read_array_array_temporal_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNumericArray
      case element_type
      when "Date"
        reader.read_array_array_date_codes_mark_range(column, mark_index, 1)
      when "Date32"
        reader.read_array_array_date32_codes_mark_range(column, mark_index, 1)
      when "DateTime"
        reader.read_array_array_datetime_seconds_mark_range(column, mark_index, 1)
      else
        if WidePart.datetime64_scale(element_type)
          reader.read_array_array_datetime64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported nested temporal Array leaf type")
        end
      end
    end

    private def read_array_array_nullable_temporal_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNullableNumericArray
      case element_type
      when "Date"
        reader.read_array_array_nullable_date_codes_mark_range(column, mark_index, 1)
      when "Date32"
        reader.read_array_array_nullable_date32_codes_mark_range(column, mark_index, 1)
      when "DateTime"
        reader.read_array_array_nullable_datetime_seconds_mark_range(column, mark_index, 1)
      else
        if WidePart.datetime64_scale(element_type)
          reader.read_array_array_nullable_datetime64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported nested nullable temporal Array leaf type")
        end
      end
    end

    private def read_array_array_time_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNumericArray
      case element_type
      when "Time"
        reader.read_array_array_time_seconds_mark_range(column, mark_index, 1)
      else
        if WidePart.time64_scale(element_type)
          reader.read_array_array_time64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported nested Time Array leaf type")
        end
      end
    end

    private def read_array_array_nullable_time_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNullableNumericArray
      case element_type
      when "Time"
        reader.read_array_array_nullable_time_seconds_mark_range(column, mark_index, 1)
      else
        if WidePart.time64_scale(element_type)
          reader.read_array_array_nullable_time64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported nested nullable Time Array leaf type")
        end
      end
    end

    private def read_array_temporal_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayNumericArray
      case element_type
      when "Date"
        reader.read_array_date_codes_mark_range(column, mark_index, 1)
      when "Date32"
        reader.read_array_date32_codes_mark_range(column, mark_index, 1)
      when "DateTime"
        reader.read_array_datetime_seconds_mark_range(column, mark_index, 1)
      else
        if WidePart.datetime64_scale(element_type)
          reader.read_array_datetime64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported temporal Array leaf type")
        end
      end
    end

    private def read_array_nullable_temporal_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayNullableNumericArray
      case element_type
      when "Date"
        reader.read_array_nullable_date_codes_mark_range(column, mark_index, 1)
      when "Date32"
        reader.read_array_nullable_date32_codes_mark_range(column, mark_index, 1)
      when "DateTime"
        reader.read_array_nullable_datetime_seconds_mark_range(column, mark_index, 1)
      else
        if WidePart.datetime64_scale(element_type)
          reader.read_array_nullable_datetime64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported nullable temporal Array leaf type")
        end
      end
    end

    private def read_array_nullable_numeric_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayNullableNumericArray
      case element_type
      when "UInt8"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt64)
      when "Int8"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int8)
      when "Int16"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int16)
      when "Int32"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int32)
      when "Int64"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int64)
      when "Int128"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int128)
      when "UInt128"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt128)
      when "Int256"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int256Value)
      when "UInt256"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt256Value)
      when "Float32"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Float32)
      when "Float64"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Float64)
      when "BFloat16"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, BFloat16Value)
      else
        raise UnsupportedFormatError.new("unsupported Array nullable numeric leaf type")
      end
    end

    private def array_nullable_numeric_materialized_bytes(
      values : WidePartArrayNullableNumericArray,
      element_type : String,
    ) : UInt64
      elements = 0_u64
      values.each do |row|
        row_elements = row.size.to_u64
        if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
          raise CorruptPartError.new("selected Array(Nullable(T)) mark element count exceeds materialization limit")
        end
        elements += row_elements
      end

      bytes_per_element = (1 + WidePart.array_numeric_payload_width(element_type)).to_u64
      if elements > UInt64::MAX // bytes_per_element
        raise CorruptPartError.new("selected Array(Nullable(T)) byte count overflows")
      end
      elements * bytes_per_element
    end

    private def array_nullable_string_materialized_bytes(
      values : WidePartArrayNullableStringArray,
    ) : {UInt64, UInt64}
      elements = 0_u64
      visible_bytes = 0_u64
      values.each do |row|
        row_elements = row.size.to_u64
        if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
          raise CorruptPartError.new("selected Array(Nullable(String)) mark element count exceeds materialization limit")
        end
        elements += row_elements
        row.each do |value|
          next if value.nil?

          string_bytes = value.bytesize.to_u64
          if string_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - visible_bytes
            raise CorruptPartError.new("selected Array(Nullable(String)) visible byte count exceeds materialization limit")
          end
          visible_bytes += string_bytes
        end
      end

      slot_bytes_per_element = WidePart::ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
      if elements > UInt64::MAX // slot_bytes_per_element
        raise CorruptPartError.new("selected Array(Nullable(String)) slot byte count overflows")
      end
      slot_bytes = elements * slot_bytes_per_element
      row_bytes_per_element = WidePart::ARRAY_NULLABLE_STRING_ROW_ACCOUNTING_BYTES
      if values.size.to_u64 > UInt64::MAX // row_bytes_per_element
        raise CorruptPartError.new("selected Array(Nullable(String)) row byte count overflows")
      end
      row_bytes = values.size.to_u64 * row_bytes_per_element
      if slot_bytes > UInt64::MAX - row_bytes || visible_bytes > UInt64::MAX - slot_bytes - row_bytes
        raise CorruptPartError.new("selected Array(Nullable(String)) materialized byte count overflows")
      end
      {visible_bytes, visible_bytes + slot_bytes + row_bytes}
    end

    private def array_tuple_materialized_bytes(
      values : Array(Array(Tuple(T, String))),
      slot_bytes_per_element : UInt64,
    ) : UInt64 forall T
      elements = 0_u64
      string_bytes = 0_u64
      values.each do |row|
        row_elements = row.size.to_u64
        if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
          raise CorruptPartError.new("selected Array(Tuple) mark element count exceeds materialization limit")
        end
        elements += row_elements
        row.each do |_number, value|
          value_bytes = value.bytesize.to_u64
          if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - string_bytes
            raise CorruptPartError.new("selected Array(Tuple) String bytes exceed materialization limit")
          end
          string_bytes += value_bytes
        end
      end

      outer_rows = values.size.to_u64
      if outer_rows > UInt64::MAX // 8_u64 || elements > UInt64::MAX // slot_bytes_per_element
        raise CorruptPartError.new("selected Array(Tuple) materialization charge overflows")
      end
      outer_bytes = outer_rows * WidePart::ARRAY_TUPLE_ROW_ACCOUNTING_BYTES
      slot_bytes = elements * slot_bytes_per_element
      if slot_bytes > UInt64::MAX - outer_bytes || string_bytes > UInt64::MAX - outer_bytes - slot_bytes
        raise CorruptPartError.new("selected Array(Tuple) materialization charge overflows")
      end
      total_bytes = outer_bytes + slot_bytes + string_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Tuple) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_tuple_uint64_uint64_materialized_bytes(
      values : Array(Array(Tuple(UInt64, UInt64))),
    ) : UInt64
      elements = 0_u64
      values.each do |row|
        row_elements = row.size.to_u64
        if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
          raise CorruptPartError.new("selected Array(Tuple) mark element count exceeds materialization limit")
        end
        elements += row_elements
      end

      outer_rows = values.size.to_u64
      if outer_rows > UInt64::MAX // WidePart::ARRAY_TUPLE_ROW_ACCOUNTING_BYTES ||
         elements > UInt64::MAX // 16_u64
        raise CorruptPartError.new("selected Array(Tuple) materialization charge overflows")
      end
      outer_bytes = outer_rows * WidePart::ARRAY_TUPLE_ROW_ACCOUNTING_BYTES
      leaf_bytes = elements * 16_u64
      raise CorruptPartError.new("selected Array(Tuple) materialization charge overflows") if leaf_bytes > UInt64::MAX - outer_bytes
      total_bytes = outer_bytes + leaf_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Tuple) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def checked_map_tuple_materialization_charge(rows : UInt64, entries : UInt64, payload_bytes : UInt64) : UInt64
      row_width = WidePart::ARRAY_TUPLE_ROW_ACCOUNTING_BYTES
      entry_width = WidePart::ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES
      if rows > WidePart::MAX_ARRAY_MARK_ROWS || entries > WidePart::MAX_ARRAY_MARK_ELEMENTS
        raise CorruptPartError.new("selected Map mark container count exceeds materialization limit")
      end
      if rows > UInt64::MAX // row_width || entries > UInt64::MAX // entry_width
        raise CorruptPartError.new("selected Map materialization charge overflows")
      end
      row_bytes = rows * row_width
      entry_bytes = entries * entry_width
      if entry_bytes > UInt64::MAX - row_bytes || payload_bytes > UInt64::MAX - row_bytes - entry_bytes
        raise CorruptPartError.new("selected Map materialization charge overflows")
      end
      charge_bytes = row_bytes + entry_bytes + payload_bytes
      if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit")
      end
      charge_bytes
    end

    private def checked_map_string_array_uint64_materialization_charge(rows : UInt64, entries : UInt64, payload_bytes : UInt64) : UInt64
      charge_bytes = checked_map_tuple_materialization_charge(rows, entries, payload_bytes)
      array_width = WidePart::MAP_ARRAY_UINT64_CONTAINER_ACCOUNTING_BYTES
      if entries > UInt64::MAX // array_width
        raise CorruptPartError.new("selected Map nested Array materialization charge overflows")
      end
      array_bytes = entries * array_width
      if array_bytes > UInt64::MAX - charge_bytes
        raise CorruptPartError.new("selected Map nested Array materialization charge overflows")
      end
      total_bytes = charge_bytes + array_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    # Charge both the physical child bytes (including hidden NULL slots) and
    # bounded per-element/row bookkeeping before materializing a selected mark.
    private def array_fixed_string_charge_bytes(raw_bytes : UInt64, width : Int32, mark_rows : UInt64, nullable : Bool) : UInt64
      slot_bytes = width.to_u64 + (nullable ? 1_u64 : 0_u64)
      raise CorruptPartError.new("selected Array(FixedString(N)) child bytes are misaligned") unless raw_bytes % slot_bytes == 0_u64
      elements = raw_bytes // slot_bytes
      raise CorruptPartError.new("selected Array(FixedString(N)) mark element count exceeds materialization limit") if elements > WidePart::MAX_ARRAY_MARK_ELEMENTS

      element_accounting = elements * WidePart::ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
      row_accounting = mark_rows * WidePart::ARRAY_NULLABLE_STRING_ROW_ACCOUNTING_BYTES
      raise CorruptPartError.new("selected Array(FixedString(N)) accounting overflows") if raw_bytes > UInt64::MAX - element_accounting - row_accounting
      raw_bytes + element_accounting + row_accounting
    end

    private def checked_array_fixed_string_elements(values, width : Int32) : UInt64
      elements = 0_u64
      values.each do |row|
        row_elements = row.size.to_u64
        if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
          raise CorruptPartError.new("selected Array(FixedString(N)) mark element count exceeds materialization limit")
        end
        elements += row_elements
        row.each do |value|
          next if value.nil?
          raise CorruptPartError.new("selected Array(FixedString(N)) element width changed") unless value.bytesize == width
        end
      end
      elements
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
      when Array(UInt128)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int256Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt256Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Decimal256Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(BFloat16Value)
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
      elsif type == "Nullable(BFloat16)"
        return reader.read_nullable_bfloat16_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum8_codes(type).nil? && type.starts_with?("Nullable(")
        return reader.read_nullable_enum8_codes_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum16_codes(type).nil? && type.starts_with?("Nullable(")
        return reader.read_nullable_enum16_codes_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal32_scale(type).nil?
        return reader.read_nullable_decimal32_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal64_scale(type).nil?
        return reader.read_nullable_decimal64_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(Int128)"
        return reader.read_nullable_int128_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(UInt128)"
        return reader.read_nullable_uint128_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(Int256)"
        return reader.read_nullable_int256_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(UInt256)"
        return reader.read_nullable_uint256_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal128_scale(type).nil?
        return reader.read_nullable_decimal128_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal256_scale(type).nil?
        return reader.read_nullable_decimal256_raw_mark_range(selected.name, mark_index, 1)
      end

      case selected.column_type
      when "Nullable(Date)"     then reader.read_nullable_date_codes_mark_range(selected.name, mark_index, 1)
      when "Nullable(Date32)"   then reader.read_nullable_date32_codes_mark_range(selected.name, mark_index, 1)
      when "Nullable(DateTime)" then reader.read_nullable_datetime_seconds_mark_range(selected.name, mark_index, 1)
      when "Nullable(Time)"     then reader.read_nullable_time_seconds_mark_range(selected.name, mark_index, 1)
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
        elsif WidePart.nullable_time64_scale(selected.column_type)
          return reader.read_nullable_time64_ticks_mark_range(selected.name, mark_index, 1)
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
      when Array(UInt128?)         then values.size
      when Array(Int256Value?)     then values.size
      when Array(UInt256Value?)    then values.size
      when Array(Decimal256Value?) then values.size
      when Array(BFloat16Value?)   then values.size
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
      when Array(UInt128?)         then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int256Value?)     then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt256Value?)    then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Decimal256Value?) then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(BFloat16Value?)   then values.to_unsafe.to_slice(values.size)[offset, size]
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

    private def array_array_uint64_materialized_bytes(values : Array(Array(Array(UInt64)))) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_elements = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(UInt64)) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_elements = inner.size.to_u64
          if row_leaf_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_elements
            raise CorruptPartError.new("selected Array(Array(UInt64)) leaf element count exceeds materialization limit")
          end
          leaf_elements += row_leaf_elements
        end
      end

      max_count = UInt64::MAX // 8_u64
      if outer_rows > max_count || inner_arrays > max_count || leaf_elements > max_count
        raise CorruptPartError.new("selected Array(Array(UInt64)) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      leaf_bytes = leaf_elements * 8_u64
      if inner_bytes > UInt64::MAX - outer_bytes || leaf_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(UInt64)) byte count overflows")
      end
      total_bytes = outer_bytes + inner_bytes + leaf_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(UInt64)) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_array_string_materialized_bytes(values : Array(Array(Array(String)))) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_strings = 0_u64
      payload_bytes = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(String)) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_strings = inner.size.to_u64
          if row_leaf_strings > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_strings
            raise CorruptPartError.new("selected Array(Array(String)) leaf string count exceeds materialization limit")
          end
          leaf_strings += row_leaf_strings
          inner.each do |value|
            value_bytes = value.bytesize.to_u64
            if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - payload_bytes
              raise CorruptPartError.new("selected Array(Array(String)) mark exceeds aggregate materialization limit")
            end
            payload_bytes += value_bytes
          end
        end
      end

      max_count = UInt64::MAX // 8_u64
      if outer_rows > max_count || inner_arrays > max_count || leaf_strings > max_count
        raise CorruptPartError.new("selected Array(Array(String)) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      string_size_bytes = leaf_strings * 8_u64
      if inner_bytes > UInt64::MAX - outer_bytes || string_size_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(String)) byte count overflows")
      end
      metadata_bytes = outer_bytes + inner_bytes + string_size_bytes
      if payload_bytes > UInt64::MAX - metadata_bytes
        raise CorruptPartError.new("selected Array(Array(String)) byte count overflows")
      end
      total_bytes = metadata_bytes + payload_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(String)) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_array_nullable_string_materialized_bytes(values : WidePartArrayArrayNullableStringArray) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_strings = 0_u64
      visible_payload_bytes = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(Nullable(String))) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_strings = inner.size.to_u64
          if row_leaf_strings > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_strings
            raise CorruptPartError.new("selected Array(Array(Nullable(String))) leaf string count exceeds materialization limit")
          end
          leaf_strings += row_leaf_strings
          inner.each do |value|
            next unless string_value = value
            value_bytes = string_value.bytesize.to_u64
            if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_payload_bytes
              raise CorruptPartError.new("selected Array(Array(Nullable(String))) mark exceeds aggregate materialization limit")
            end
            visible_payload_bytes += value_bytes
          end
        end
      end

      max_offset_count = UInt64::MAX // 8_u64
      if outer_rows > max_offset_count || inner_arrays > max_offset_count || leaf_strings > UInt64::MAX // 9_u64
        raise CorruptPartError.new("selected Array(Array(Nullable(String))) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      leaf_bytes = leaf_strings * 9_u64
      if inner_bytes > UInt64::MAX - outer_bytes || leaf_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(Nullable(String))) byte count overflows")
      end
      metadata_bytes = outer_bytes + inner_bytes + leaf_bytes
      if visible_payload_bytes > UInt64::MAX - metadata_bytes
        raise CorruptPartError.new("selected Array(Array(Nullable(String))) byte count overflows")
      end
      total_bytes = metadata_bytes + visible_payload_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(Nullable(String))) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_array_nullable_uint64_materialized_bytes(values : Array(Array(Array(UInt64?)))) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_elements = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_elements = inner.size.to_u64
          if row_leaf_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_elements
            raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) leaf element count exceeds materialization limit")
          end
          leaf_elements += row_leaf_elements
        end
      end

      max_count = UInt64::MAX // 8_u64
      if outer_rows > max_count || inner_arrays > max_count || leaf_elements > max_count
        raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      if leaf_elements > UInt64::MAX // 9_u64
        raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) byte count overflows")
      end
      leaf_bytes = leaf_elements * 9_u64
      if inner_bytes > UInt64::MAX - outer_bytes || leaf_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) byte count overflows")
      end
      total_bytes = outer_bytes + inner_bytes + leaf_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_array_nullable_numeric_materialized_bytes(
      values : WidePartArrayArrayNullableNumericArray,
      element_type : String,
    ) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_elements = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(Nullable(T))) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_elements = inner.size.to_u64
          if row_leaf_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_elements
            raise CorruptPartError.new("selected Array(Array(Nullable(T))) leaf element count exceeds materialization limit")
          end
          leaf_elements += row_leaf_elements
        end
      end

      max_offset_count = UInt64::MAX // 8_u64
      bytes_per_leaf = (1 + WidePart.array_numeric_payload_width(element_type)).to_u64
      if outer_rows > max_offset_count || inner_arrays > max_offset_count || leaf_elements > UInt64::MAX // bytes_per_leaf
        raise CorruptPartError.new("selected Array(Array(Nullable(T))) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      leaf_bytes = leaf_elements * bytes_per_leaf
      if inner_bytes > UInt64::MAX - outer_bytes || leaf_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(Nullable(T))) byte count overflows")
      end
      total_bytes = outer_bytes + inner_bytes + leaf_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(Nullable(T))) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_array_numeric_materialized_bytes(
      values : WidePartArrayArrayNumericArray,
      element_type : String,
    ) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_elements = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(T)) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_elements = inner.size.to_u64
          if row_leaf_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_elements
            raise CorruptPartError.new("selected Array(Array(T)) leaf element count exceeds materialization limit")
          end
          leaf_elements += row_leaf_elements
        end
      end

      width = WidePart.array_numeric_payload_width(element_type).to_u64
      max_offset_count = UInt64::MAX // 8_u64
      if outer_rows > max_offset_count || inner_arrays > max_offset_count || leaf_elements > UInt64::MAX // width
        raise CorruptPartError.new("selected Array(Array(T)) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      leaf_bytes = leaf_elements * width
      if inner_bytes > UInt64::MAX - outer_bytes || leaf_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(T)) byte count overflows")
      end
      total_bytes = outer_bytes + inner_bytes + leaf_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(T)) mark exceeds aggregate materialization limit")
      end
      total_bytes
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
