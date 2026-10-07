module CrystalClick
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
    @qbit_values : Hash(String, Slice(QBitValue))
    @point_values : Hash(String, Slice(WidePointValue))
    @geo_array_rows : Hash(String, Slice(WideGeoArrayRow)) = Hash(String, Slice(WideGeoArrayRow)).new
    @geometry_rows : Hash(String, Slice(WideGeometryRow)) = Hash(String, Slice(WideGeometryRow)).new
    @object_documents : Hash(String, Slice(ObjectDocument)) = Hash(String, Slice(ObjectDocument)).new
    @array_object_documents : Hash(String, Slice(Array(ObjectDocument))) = Hash(String, Slice(Array(ObjectDocument))).new
    @recursive_values : Hash(String, Slice(StorageColumnValue)) = Hash(String, Slice(StorageColumnValue)).new
    @dynamic_bulk_values : Hash(String, Slice(BinaryValue)) = Hash(String, Slice(BinaryValue)).new
    @nullable_qbit_values : Hash(String, Slice(QBitValue?))
    @aggregate_count_state_values : Hash(String, Slice(BinaryValue)) = Hash(String, Slice(BinaryValue)).new
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
    @tuple_row_values : Hash(String, Slice(WideTupleRow))
    @array_tuple_row_values : Hash(String, Slice(WideArrayTupleRow))
    @map_tuple_row_values : Hash(String, Slice(WideMapTupleRow))
    @map_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64, String))))
    @map_uint64_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64))))
    @map_string_uint64_values : Hash(String, Slice(Array(Tuple(String, UInt64))))
    @map_string_array_uint64_values : Hash(String, Slice(Array(Tuple(String, Array(UInt64)))))
    @array_map_string_uint64_values : Hash(String, Slice(Array(Array(Tuple(String, UInt64)))))
    @array_map_numeric_values : Hash(String, WidePartArrayMapNumericSliceBase)
    @map_string_array_nullable_uint64_values : Hash(String, Slice(Array(Tuple(String, Array(UInt64?)))))
    @map_string_array_nullable_string_values : Hash(String, Slice(Array(Tuple(String, Array(String?)))))
    @map_uint64_array_nullable_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?)))))
    @map_uint64_array_nullable_string_values : Hash(String, Slice(Array(Tuple(UInt64, Array(String?)))))
    @map_uint64_array_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64)))))
    @map_string_array_string_values : Hash(String, Slice(Array(Tuple(String, Array(String)))))
    @map_uint64_array_string_values : Hash(String, Slice(Array(Tuple(UInt64, Array(String)))))
    @map_string_string_values : Hash(String, Slice(Array(Tuple(String, String))))
    @map_uint64_nullable_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64?))))
    @map_string_nullable_uint64_values : Hash(String, Slice(Array(Tuple(String, UInt64?))))
    @map_uint64_nullable_string_values : Hash(String, Slice(Array(Tuple(UInt64, String?))))
    @map_string_nullable_string_values : Hash(String, Slice(Array(Tuple(String, String?))))
    @map_uint64_numeric_values : Hash(String, WidePartNumericMapSliceBase)
    @map_string_numeric_values : Hash(String, WidePartNumericMapSliceBase)

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
      @qbit_values = Hash(String, Slice(QBitValue)).new
      @point_values = Hash(String, Slice(WidePointValue)).new
      @nullable_qbit_values = Hash(String, Slice(QBitValue?)).new
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
      @tuple_row_values = Hash(String, Slice(WideTupleRow)).new
      @array_tuple_row_values = Hash(String, Slice(WideArrayTupleRow)).new
      @map_tuple_row_values = Hash(String, Slice(WideMapTupleRow)).new
      @map_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
      @map_uint64_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
      @map_string_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64)))).new
      @map_string_array_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64))))).new
      @array_map_string_uint64_values = Hash(String, Slice(Array(Array(Tuple(String, UInt64))))).new
      @array_map_numeric_values = Hash(String, WidePartArrayMapNumericSliceBase).new
      @map_string_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))).new
      @map_string_array_nullable_string_values = Hash(String, Slice(Array(Tuple(String, Array(String?))))).new
      @map_uint64_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))).new
      @map_uint64_array_nullable_string_values = Hash(String, Slice(Array(Tuple(UInt64, Array(String?))))).new
      @map_string_string_values = Hash(String, Slice(Array(Tuple(String, String)))).new
      @map_uint64_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))).new
      @map_string_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64?)))).new
      @map_uint64_nullable_string_values = Hash(String, Slice(Array(Tuple(UInt64, String?)))).new
      @map_string_nullable_string_values = Hash(String, Slice(Array(Tuple(String, String?)))).new
      @map_uint64_numeric_values = Hash(String, WidePartNumericMapSliceBase).new
      @map_string_numeric_values = Hash(String, WidePartNumericMapSliceBase).new
      @map_uint64_array_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64))))).new
      @map_string_array_string_values = Hash(String, Slice(Array(Tuple(String, Array(String))))).new
      @map_uint64_array_string_values = Hash(String, Slice(Array(Tuple(UInt64, Array(String))))).new
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
      @qbit_values = Hash(String, Slice(QBitValue)).new
      @point_values = Hash(String, Slice(WidePointValue)).new
      @nullable_qbit_values = Hash(String, Slice(QBitValue?)).new
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
      @tuple_row_values = Hash(String, Slice(WideTupleRow)).new
      @array_tuple_row_values = Hash(String, Slice(WideArrayTupleRow)).new
      @map_tuple_row_values = Hash(String, Slice(WideMapTupleRow)).new
      @map_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
      @map_uint64_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
      @map_string_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64)))).new
      @map_string_array_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64))))).new
      @array_map_string_uint64_values = Hash(String, Slice(Array(Array(Tuple(String, UInt64))))).new
      @array_map_numeric_values = Hash(String, WidePartArrayMapNumericSliceBase).new
      @map_string_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))).new
      @map_string_array_nullable_string_values = Hash(String, Slice(Array(Tuple(String, Array(String?))))).new
      @map_uint64_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))).new
      @map_uint64_array_nullable_string_values = Hash(String, Slice(Array(Tuple(UInt64, Array(String?))))).new
      @map_string_string_values = Hash(String, Slice(Array(Tuple(String, String)))).new
      @map_uint64_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))).new
      @map_string_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64?)))).new
      @map_uint64_nullable_string_values = Hash(String, Slice(Array(Tuple(UInt64, String?)))).new
      @map_string_nullable_string_values = Hash(String, Slice(Array(Tuple(String, String?)))).new
      @map_uint64_numeric_values = Hash(String, WidePartNumericMapSliceBase).new
      @map_string_numeric_values = Hash(String, WidePartNumericMapSliceBase).new
      @map_uint64_array_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64))))).new
      @map_string_array_string_values = Hash(String, Slice(Array(Tuple(String, Array(String))))).new
      @map_uint64_array_string_values = Hash(String, Slice(Array(Tuple(UInt64, Array(String))))).new
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
      @qbit_values = Hash(String, Slice(QBitValue)).new
      @point_values = Hash(String, Slice(WidePointValue)).new
      @nullable_qbit_values = Hash(String, Slice(QBitValue?)).new
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
      @tuple_row_values = Hash(String, Slice(WideTupleRow)).new
      @array_tuple_row_values = Hash(String, Slice(WideArrayTupleRow)).new
      @map_tuple_row_values = Hash(String, Slice(WideMapTupleRow)).new
      @map_uint64_string_values = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
      @map_uint64_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
      @map_string_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64)))).new
      @map_string_array_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64))))).new
      @array_map_string_uint64_values = Hash(String, Slice(Array(Array(Tuple(String, UInt64))))).new
      @array_map_numeric_values = Hash(String, WidePartArrayMapNumericSliceBase).new
      @map_string_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))).new
      @map_string_array_nullable_string_values = Hash(String, Slice(Array(Tuple(String, Array(String?))))).new
      @map_uint64_array_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))).new
      @map_uint64_array_nullable_string_values = Hash(String, Slice(Array(Tuple(UInt64, Array(String?))))).new
      @map_string_string_values = Hash(String, Slice(Array(Tuple(String, String)))).new
      @map_uint64_nullable_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))).new
      @map_string_nullable_uint64_values = Hash(String, Slice(Array(Tuple(String, UInt64?)))).new
      @map_uint64_nullable_string_values = Hash(String, Slice(Array(Tuple(UInt64, String?)))).new
      @map_string_nullable_string_values = Hash(String, Slice(Array(Tuple(String, String?)))).new
      @map_uint64_numeric_values = Hash(String, WidePartNumericMapSliceBase).new
      @map_string_numeric_values = Hash(String, WidePartNumericMapSliceBase).new
      @map_uint64_array_uint64_values = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64))))).new
      @map_string_array_string_values = Hash(String, Slice(Array(Tuple(String, Array(String))))).new
      @map_uint64_array_string_values = Hash(String, Slice(Array(Tuple(UInt64, Array(String))))).new
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
      @map_uint64_array_nullable_string_values : Hash(String, Slice(Array(Tuple(UInt64, Array(String?))))) = Hash(String, Slice(Array(Tuple(UInt64, Array(String?))))).new,
      @map_uint64_array_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64))))) = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64))))).new,
      @map_string_array_string_values : Hash(String, Slice(Array(Tuple(String, Array(String))))) = Hash(String, Slice(Array(Tuple(String, Array(String))))).new,
      @map_uint64_array_string_values : Hash(String, Slice(Array(Tuple(UInt64, Array(String))))) = Hash(String, Slice(Array(Tuple(UInt64, Array(String))))).new,
      map_uint64_numeric_values : Hash(String, WidePartNumericMapSliceBase) = Hash(String, WidePartNumericMapSliceBase).new,
      map_string_numeric_values : Hash(String, WidePartNumericMapSliceBase) = Hash(String, WidePartNumericMapSliceBase).new,
      array_map_string_uint64_values : Hash(String, Slice(Array(Array(Tuple(String, UInt64))))) = Hash(String, Slice(Array(Array(Tuple(String, UInt64))))).new,
      @array_map_numeric_values : Hash(String, WidePartArrayMapNumericSliceBase) = Hash(String, WidePartArrayMapNumericSliceBase).new,
      tuple_row_values : Hash(String, Slice(WideTupleRow)) = Hash(String, Slice(WideTupleRow)).new,
    )
      @qbit_values = Hash(String, Slice(QBitValue)).new
      @point_values = Hash(String, Slice(WidePointValue)).new
      @nullable_qbit_values = Hash(String, Slice(QBitValue?)).new
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
      @array_map_string_uint64_values = array_map_string_uint64_values
      @map_string_array_nullable_uint64_values = map_string_array_nullable_uint64_values
      @map_uint64_array_nullable_uint64_values = map_uint64_array_nullable_uint64_values
      @map_string_string_values = map_string_string_values
      @map_uint64_nullable_uint64_values = map_uint64_nullable_uint64_values
      @map_string_nullable_uint64_values = map_string_nullable_uint64_values
      @map_uint64_nullable_string_values = map_uint64_nullable_string_values
      @map_string_nullable_string_values = map_string_nullable_string_values
      @map_uint64_array_uint64_values = map_uint64_array_uint64_values
      @map_string_array_string_values = map_string_array_string_values
      @map_uint64_array_string_values = map_uint64_array_string_values
      @map_uint64_numeric_values = map_uint64_numeric_values
      @map_string_numeric_values = map_string_numeric_values
      @tuple_row_values = tuple_row_values
      @array_tuple_row_values = Hash(String, Slice(WideArrayTupleRow)).new
      @map_tuple_row_values = Hash(String, Slice(WideMapTupleRow)).new
    end

    def column_names : Array(String)
      @column_names.dup
    end

    # Return the exact declaration for a selected column. Semantic values such
    # as DateTime64 ticks need this metadata to retain their precision label.
    def column_type_for(column : String) : String
      @column_types[column_index(column)]
    end

    def qbits_for(column : String) : Slice(QBitValue)
      index = column_index(column)
      plan = QBitColumnType.for_type(@column_types[index]) ||
             raise(UnsupportedFormatError.new("QBit accessor requires an exact canonical QBit column"))
      raise UnsupportedFormatError.new("QBit accessor requires a non-nullable QBit column") if plan.nullable
      @qbit_values[column]? || raise(UnsupportedFormatError.new("QBit column was not materialized in this batch"))
    end

    # Return nominal Count states only for the caller's exact admitted
    # descriptor. The UInt64 payload carrier is not exposed through a numeric
    # accessor, even though each BinaryValue stores that carrier internally.
    def aggregate_count_states_for(column : String, expected_type : BinaryDataType) : Slice(BinaryValue)
      index = column_index(column)
      plan = WideAggregateCountStoragePlan.require(expected_type)
      unless @column_types[index] == plan.type_name
        raise UnsupportedFormatError.new("AggregateFunction(count) accessor does not match the selected descriptor")
      end
      @aggregate_count_state_values[column]? ||
        raise UnsupportedFormatError.new("AggregateFunction(count) column was not materialized in this batch")
    end

    # Internal table-scan hook. The callback receives a view into the owned
    # per-mark state array, matching the lifetime of other batch slices.
    def install_aggregate_count_states(column : String, values : Slice(BinaryValue), expected_rows : Int) : Nil
      index = column_index(column)
      plan = WideAggregateCountStoragePlan.for_type_name(@column_types[index]) ||
             raise(CorruptPartError.new("AggregateFunction(count) materializer received a non-Count column"))
      raise CorruptPartError.new("AggregateFunction(count) batch slice row count mismatch") unless values.size == expected_rows
      values.each do |value|
        unless value.type == plan.data_type
          raise CorruptPartError.new("AggregateFunction(count) batch value type differs from column declaration")
        end
      end
      @aggregate_count_state_values[column] = values
      nil
    end

    def nullable_qbits_for(column : String) : Slice(QBitValue?)
      index = column_index(column)
      plan = QBitColumnType.for_type(@column_types[index]) ||
             raise(UnsupportedFormatError.new("QBit accessor requires an exact canonical QBit column"))
      raise UnsupportedFormatError.new("QBit accessor requires Nullable(QBit)") unless plan.nullable
      @nullable_qbit_values[column]? || raise(UnsupportedFormatError.new("Nullable(QBit) column was not materialized in this batch"))
    end

    def geo_array_rows_for(column : String) : Slice(WideGeoArrayRow)
      index = column_index(column)
      raise UnsupportedFormatError.new("Geo Array accessor requires an exact admitted Geo Array column") unless GeoArrayColumnType.for_type(@column_types[index])
      @geo_array_rows[column]? || raise(UnsupportedFormatError.new("Geo Array column was not materialized in this batch"))
    end

    def install_geo_array_rows(column : String, values : Slice(WideGeoArrayRow), expected_rows : Int) : Nil
      index = column_index(column)
      raise CorruptPartError.new("Geo Array materializer received an unsupported column") unless GeoArrayColumnType.for_type(@column_types[index])
      raise CorruptPartError.new("Geo Array batch slice row count mismatch") unless values.size == expected_rows
      values.each do |row|
        raise CorruptPartError.new("Geo Array row nominal type differs from column declaration") unless row.data.type_name == @column_types[index]
      end
      @geo_array_rows[column] = values
      nil
    end

    def point_values_for(column : String) : Slice(WidePointValue)
      index = column_index(column)
      raise UnsupportedFormatError.new("Point accessor requires an exact Point column") unless PointColumnType.for_type(@column_types[index])
      @point_values[column]? || raise(UnsupportedFormatError.new("Point column was not materialized in this batch"))
    end

    def geometry_rows_for(column : String) : Slice(WideGeometryRow)
      index = column_index(column)
      raise UnsupportedFormatError.new("Geometry accessor requires the exact Geometry column") unless GeometryColumnType.for_type(@column_types[index])
      @geometry_rows[column]? || raise(UnsupportedFormatError.new("Geometry column was not materialized in this batch"))
    end

    # Return Object document handles borrowed from this callback's mark owner.
    # The handles are immutable and may be retained; the containing Slice is a
    # callback-scoped view, like every other batch slice.
    def object_documents_for(column : String) : Slice(ObjectDocument)
      index = column_index(column)
      raise UnsupportedFormatError.new("Object accessor requires an exact JSON column") unless WidePart.json_type?(@column_types[index])
      @object_documents[column]? || raise(UnsupportedFormatError.new("Object column was not materialized in this batch"))
    end

    # Internal table-scan hook for one borrowed full-mark row slice.
    def install_object_documents(column : String, values : Slice(ObjectDocument), expected_rows : Int) : Nil
      index = column_index(column)
      raise CorruptPartError.new("Object materializer received a non-JSON column") unless WidePart.json_type?(@column_types[index])
      raise CorruptPartError.new("Object batch slice row count mismatch") unless values.size == expected_rows
      @object_documents[column] = values
      nil
    end

    # Return one Array(JSON) row (an owned child-document Array); the outer
    # Slice is callback-scoped, while the nested immutable documents may be
    # retained under the same rules as Object document handles.
    def array_object_documents_for(column : String) : Slice(Array(ObjectDocument))
      index = column_index(column)
      unless ArrayObjectColumnReader.schema_for_source_declaration(@column_types[index])
        raise UnsupportedFormatError.new("Array(JSON) accessor requires an exact normalized declaration")
      end
      @array_object_documents[column]? || raise(UnsupportedFormatError.new("Array(JSON) column was not materialized in this batch"))
    end

    # Internal table-scan hook for a borrowed outer-row slice. Each row keeps
    # its own child array and no Array(JSON) occurrence state is shared.
    def install_array_object_documents(column : String, values : Slice(Array(ObjectDocument)), expected_rows : Int) : Nil
      index = column_index(column)
      unless ArrayObjectColumnReader.schema_for_source_declaration(@column_types[index])
        raise CorruptPartError.new("Array(JSON) materializer received a non-admitted declaration")
      end
      raise CorruptPartError.new("Array(JSON) batch slice row count mismatch") unless values.size == expected_rows
      @array_object_documents[column] = values
      nil
    end

    # Return values for a recursively admitted root Tuple/Array containing
    # JSON leaves. The outer slice is callback-scoped; immutable nested values
    # may be retained by callers.
    def recursive_values_for(column : String) : Slice(StorageColumnValue)
      index = column_index(column)
      schema = StorageColumnSchema.parse(@column_types[index])
      unless (schema.tuple? || schema.array?) && schema.has_json? && schema.declaration == @column_types[index]
        raise UnsupportedFormatError.new("recursive storage accessor requires an exact Tuple/Array containing JSON")
      end
      @recursive_values[column]? || raise(UnsupportedFormatError.new("recursive storage column was not materialized in this batch"))
    end

    # Internal table-scan hook for one borrowed parent-row slice.
    def install_recursive_values(column : String, values : Slice(StorageColumnValue), expected_rows : Int) : Nil
      index = column_index(column)
      schema = StorageColumnSchema.parse(@column_types[index])
      unless (schema.tuple? || schema.array?) && schema.has_json? && schema.declaration == @column_types[index]
        raise CorruptPartError.new("recursive storage materializer received a non-admitted Tuple/Array declaration")
      end
      raise CorruptPartError.new("recursive storage batch slice row count mismatch") unless values.size == expected_rows
      @recursive_values[column] = values
      nil
    end

    # Return generic Dynamic-bearing BinaryBulk rows. The outer slice is
    # callback-scoped; immutable BinaryValue trees may be retained by callers.
    # Bare Dynamic keeps its existing specialized accessor and is not admitted
    # through this generic declaration contract.
    def dynamic_bulk_values_for(column : String) : Slice(BinaryValue)
      index = column_index(column)
      expected_type = DynamicBulkColumnDeclaration.parse(@column_types[index])
      unless expected_type
        raise UnsupportedFormatError.new("Dynamic bulk accessor requires an admitted Dynamic-bearing declaration")
      end
      @dynamic_bulk_values[column]? || raise(UnsupportedFormatError.new("Dynamic bulk column was not materialized in this batch"))
    end

    # Internal table-scan hook for one borrowed parent-row slice.
    def install_dynamic_bulk_values(column : String, values : Slice(BinaryValue), expected_rows : Int) : Nil
      index = column_index(column)
      expected_type = DynamicBulkColumnDeclaration.parse(@column_types[index])
      unless expected_type
        raise CorruptPartError.new("Dynamic bulk materializer received a non-admitted declaration")
      end
      raise CorruptPartError.new("Dynamic bulk batch slice row count mismatch") unless values.size == expected_rows
      values.each do |value|
        unless value.type == expected_type
          raise CorruptPartError.new("Dynamic bulk batch value type differs from its declaration")
        end
      end
      @dynamic_bulk_values[column] = values
      nil
    end

    def install_geometry_rows(column : String, values : Slice(WideGeometryRow), expected_rows : Int) : Nil
      index = column_index(column)
      raise CorruptPartError.new("Geometry materializer received a non-Geometry column") unless GeometryColumnType.for_type(@column_types[index])
      raise CorruptPartError.new("Geometry batch slice row count mismatch") unless values.size == expected_rows
      values.each do |row|
        unless row.type_name == @column_types[index]
          raise CorruptPartError.new("Geometry row nominal type differs from column declaration")
        end
      end
      @geometry_rows[column] = values
      nil
    end

    def install_point_values(column : String, values : Slice(WidePointValue), expected_rows : Int) : Nil
      index = column_index(column)
      raise CorruptPartError.new("Point materializer received a non-Point column") unless PointColumnType.for_type(@column_types[index])
      raise CorruptPartError.new("Point batch slice row count mismatch") unless values.size == expected_rows
      @point_values[column] = values
      nil
    end

    # Internal table-scan hook. Values remain borrowed slices into this
    # callback's per-mark owner arrays, matching the other batch accessors.
    def install_qbit_values(column : String, values : Slice(QBitValue), expected_rows : Int) : Nil
      index = column_index(column)
      plan = QBitColumnType.for_type(@column_types[index]) ||
             raise(CorruptPartError.new("QBit materializer received a non-QBit column"))
      raise CorruptPartError.new("QBit materializer received Nullable(QBit)") if plan.nullable
      raise CorruptPartError.new("QBit batch slice row count mismatch") unless values.size == expected_rows
      values.each do |value|
        raise CorruptPartError.new("QBit batch value type differs from column declaration") unless value.type == plan.value_type
      end
      @qbit_values[column] = values
      nil
    end

    def install_nullable_qbit_values(column : String, values : Slice(QBitValue?), expected_rows : Int) : Nil
      index = column_index(column)
      plan = QBitColumnType.for_type(@column_types[index]) ||
             raise(CorruptPartError.new("QBit materializer received a non-QBit column"))
      raise(CorruptPartError.new("QBit materializer received a non-nullable QBit")) unless plan.nullable
      raise CorruptPartError.new("Nullable(QBit) batch slice row count mismatch") unless values.size == expected_rows
      values.each do |value|
        next unless value
        raise CorruptPartError.new("Nullable(QBit) batch value type differs from column declaration") unless value.type == plan.value_type
      end
      @nullable_qbit_values[column] = values
      nil
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

    # Return raw UInt32 epoch seconds for a DateTime column while retaining
    # its exact declared timezone in #column_types.
    def datetime_seconds_for(column : String) : Slice(UInt32)
      index = column_index(column)
      datetime_type = DateTimeColumnType.parse_leaf(@column_types[index])
      raise UnsupportedFormatError.new("DateTime accessor requires an exact DateTime column") unless datetime_type && datetime_type.family == DateTimeColumnType::Family::DateTime
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

    # Return raw signed Interval counts only for a scalar exact Interval kind.
    def interval_counts_for(column : String) : Slice(Int64)
      index = column_index(column)
      interval_type = IntervalColumnType.parse(@column_types[index])
      unless interval_type && interval_type.shape == IntervalColumnType::Shape::Scalar
        raise UnsupportedFormatError.new("Interval accessor requires an exact scalar Interval column")
      end
      return @typed_numeric_values[column].as(Slice(Int64)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int64))
    end

    # Return raw UInt64 children only for an exact scalar
    # SimpleAggregateFunction declaration; primitive UInt64 accessors remain
    # closed over their own exact type.
    def simple_aggregate_uint64s_for(column : String) : Slice(UInt64)
      index = column_index(column)
      aggregate_type = SimpleAggregateColumnType.parse(@column_types[index])
      unless aggregate_type && aggregate_type.shape == SimpleAggregateColumnType::Shape::Scalar && aggregate_type.storage_type_name == "UInt64"
        raise UnsupportedFormatError.new("SimpleAggregateFunction accessor requires an exact scalar UInt64 profile")
      end
      return @typed_numeric_values[column].as(Slice(UInt64)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(UInt64))
    end

    # Return raw stored children only when the requested primitive carrier is
    # the exact declared SimpleAggregateFunction child, not merely equal width.
    def simple_aggregate_values_for(column : String, type : T.class) : Slice(T) forall T
      index = column_index(column)
      aggregate_type = SimpleAggregateColumnType.parse(@column_types[index])
      expected_storage = SimpleAggregateColumnType.storage_name(type)
      unless aggregate_type && aggregate_type.shape == SimpleAggregateColumnType::Shape::Scalar && aggregate_type.storage_type_name == expected_storage
        raise UnsupportedFormatError.new("typed SimpleAggregateFunction accessor does not match selected carrier")
      end
      return @typed_numeric_values[column].as(Slice(T)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(T))
    end

    def simple_aggregate_decimal32_raw_for(column : String, function : BinarySimpleAggregateType::Function, precision : Int32, scale : Int32) : Slice(Int32)
      index = column_index(column)
      plan = SimpleAggregateDecimalStoragePlan.require(@column_types[index], function, precision, scale)
      plan.validate_carrier!(Int32)
      return @typed_numeric_values[column].as(Slice(Int32)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int32))
    end

    def simple_aggregate_decimal64_raw_for(column : String, function : BinarySimpleAggregateType::Function, precision : Int32, scale : Int32) : Slice(Int64)
      index = column_index(column)
      plan = SimpleAggregateDecimalStoragePlan.require(@column_types[index], function, precision, scale)
      plan.validate_carrier!(Int64)
      return @typed_numeric_values[column].as(Slice(Int64)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int64))
    end

    def simple_aggregate_decimal128_raw_for(column : String, function : BinarySimpleAggregateType::Function, precision : Int32, scale : Int32) : Slice(Int128)
      index = column_index(column)
      plan = SimpleAggregateDecimalStoragePlan.require(@column_types[index], function, precision, scale)
      plan.validate_carrier!(Int128)
      return @typed_numeric_values[column].as(Slice(Int128)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int128))
    end

    def simple_aggregate_decimal256_raw_for(column : String, function : BinarySimpleAggregateType::Function, precision : Int32, scale : Int32) : Slice(Decimal256Value)
      index = column_index(column)
      plan = SimpleAggregateDecimalStoragePlan.require(@column_types[index], function, precision, scale)
      plan.validate_carrier!(Decimal256Value)
      return @typed_numeric_values[column].as(Slice(Decimal256Value)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Decimal256Value))
    end

    def simple_aggregate_temporal_raw_values_for(
      column : String,
      function : BinarySimpleAggregateType::Function,
      storage_type_name : String,
      type : T.class,
    ) : Slice(T) forall T
      index = column_index(column)
      plan = SimpleAggregateTemporalStoragePlan.require(@column_types[index], function, storage_type_name)
      plan.validate_carrier!(type)
      return @typed_numeric_values[column].as(Slice(T)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(T))
    end

    def simple_aggregate_strings_for(column : String) : Slice(String)
      index = column_index(column)
      plan = SimpleAggregateTextStoragePlan.for_type_name(@column_types[index])
      unless plan && !plan.nullable? && plan.variable_string?
        raise UnsupportedFormatError.new("SimpleAggregateFunction accessor requires exact scalar String storage")
      end
      @string_values[column]? || raise(UnsupportedFormatError.new("SimpleAggregateFunction(String) column was not materialized in this batch"))
    end

    def simple_aggregate_fixed_strings_for(column : String) : Slice(String)
      index = column_index(column)
      plan = SimpleAggregateTextStoragePlan.for_type_name(@column_types[index])
      unless plan && !plan.nullable? && !plan.fixed_string_width.nil?
        raise UnsupportedFormatError.new("SimpleAggregateFunction accessor requires exact scalar FixedString(N) storage")
      end
      @fixed_string_values[column]? || raise(UnsupportedFormatError.new("SimpleAggregateFunction(FixedString) column was not materialized in this batch"))
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
      raise UnsupportedFormatError.new("Decimal32 accessor requires canonical Decimal(P, S) with P in 1..9") unless WidePart.decimal32_scale(@column_types[index])
      return @typed_numeric_values[column].as(Slice(Int32)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int32))
    end

    def nullable_decimal32_raw_for(column : String) : Slice(Int32?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal32 accessor requires canonical Nullable(Decimal(P, S)) with P in 1..9") unless WidePart.nullable_decimal32_scale(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(Int32?))) || raise(UnsupportedFormatError.new("Nullable(Decimal32) column was not materialized in this batch"))
    end

    def decimal64_raw_for(column : String) : Slice(Int64)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires canonical Decimal(P, S) with P in 10..18") unless WidePart.decimal64_scale(@column_types[index])
      return @typed_numeric_values[column].as(Slice(Int64)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int64))
    end

    def nullable_decimal64_raw_for(column : String) : Slice(Int64?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires canonical Nullable(Decimal(P, S)) with P in 10..18") unless WidePart.nullable_decimal64_scale(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(Int64?))) || raise(UnsupportedFormatError.new("Nullable(Decimal64) column was not materialized in this batch"))
    end

    def decimal128_raw_for(column : String) : Slice(Int128)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires canonical Decimal(P, S) with P in 19..38") unless WidePart.decimal128_scale(@column_types[index])
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
      raise UnsupportedFormatError.new("Decimal128 accessor requires canonical Nullable(Decimal(P, S)) with P in 19..38") unless WidePart.nullable_decimal128_scale(@column_types[index])
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
      raise UnsupportedFormatError.new("Decimal256 accessor requires canonical Decimal(P, S) with P in 39..76") unless WidePart.decimal256_scale(@column_types[index])
      return @typed_numeric_values[column].as(Slice(Decimal256Value)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Decimal256Value))
    end

    def nullable_decimal256_raw_for(column : String) : Slice(Decimal256Value?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal256 accessor requires canonical Nullable(Decimal(P, S)) with P in 39..76") unless WidePart.nullable_decimal256_scale(@column_types[index])
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

    def dynamic_strings_for(column : String) : Slice(String)
      index = column_index(column)
      raise UnsupportedFormatError.new("Dynamic accessor requires an exact Dynamic column") unless @column_types[index] == "Dynamic"
      if @variant_string_uint64_values.has_key?(column)
        raise UnsupportedFormatError.new("String-only Dynamic accessor rejects mixed Dynamic batches")
      end
      @string_values[column]? || raise(UnsupportedFormatError.new("Dynamic column was not materialized in this batch"))
    end

    def dynamic_string_uint64_for(column : String) : Slice(VariantStringUInt64Value)
      index = column_index(column)
      raise UnsupportedFormatError.new("mixed Dynamic accessor requires an exact Dynamic column") unless @column_types[index] == "Dynamic"
      @variant_string_uint64_values[column]? || raise(UnsupportedFormatError.new("mixed Dynamic column was not materialized in this batch"))
    end

    def dynamic_string_uint64_profile?(column : String) : Bool
      index = column_index(column)
      raise UnsupportedFormatError.new("Dynamic profile query requires an exact Dynamic column") unless @column_types[index] == "Dynamic"
      @variant_string_uint64_values.has_key?(column)
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
      raise UnsupportedFormatError.new("typed Decimal32 Array accessor requires Array(Decimal(P, S)) with P in 1..9") unless WidePart.array_decimal32_scale(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal32 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int32)))
    end

    def array_nullable_decimal32_raw_for(column : String) : Slice(Array(Int32?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed nullable Decimal32 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 1..9") unless WidePart.array_nullable_decimal32_scale(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal32 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int32?)))
    end

    def array_decimal64_raw_for(column : String) : Slice(Array(Int64))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Decimal64 Array accessor requires Array(Decimal(P, S)) with P in 10..18") unless WidePart.array_decimal64_scale(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal64 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int64)))
    end

    def array_nullable_decimal64_raw_for(column : String) : Slice(Array(Int64?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed nullable Decimal64 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 10..18") unless WidePart.array_nullable_decimal64_scale(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal64 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int64?)))
    end

    def array_decimal128_raw_for(column : String) : Slice(Array(Int128))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Decimal128 Array accessor requires Array(Decimal(P, S)) with P in 19..38") unless WidePart.array_decimal128_scale(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal128 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int128)))
    end

    def array_nullable_decimal128_raw_for(column : String) : Slice(Array(Int128?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed nullable Decimal128 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 19..38") unless WidePart.array_nullable_decimal128_scale(@column_types[index])
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal128 Array column was not materialized in this batch"))
      values.as(Slice(Array(Int128?)))
    end

    def array_decimal256_raw_for(column : String) : Slice(Array(Decimal256Value))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed Decimal256 Array accessor requires Array(Decimal(P, S)) with P in 39..76") unless WidePart.array_decimal256_scale(@column_types[index])
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal256 Array column was not materialized in this batch"))
      values.as(Slice(Array(Decimal256Value)))
    end

    def array_nullable_decimal256_raw_for(column : String) : Slice(Array(Decimal256Value?))
      index = column_index(column)
      raise UnsupportedFormatError.new("typed nullable Decimal256 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 39..76") unless WidePart.array_nullable_decimal256_scale(@column_types[index])
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
      unless WidePart.temporal_array_element_type(@column_types[index]).try { |actual| WidePart.same_temporal_leaf_family?(actual, element_type) } &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed temporal Array accessor requires an exact semantic temporal column")
      end
      values = @array_numeric_values[column]? || raise(UnsupportedFormatError.new("temporal Array column was not materialized in this batch"))
      values.as(Slice(Array(T)))
    end

    private def array_nullable_temporal_values_for(column : String, element_type : String, type : T.class) : Slice(Array(T?)) forall T
      index = column_index(column)
      unless WidePart.nullable_temporal_array_element_type(@column_types[index]).try { |actual| WidePart.same_temporal_leaf_family?(actual, element_type) } &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nullable temporal Array accessor requires an exact semantic temporal column")
      end
      values = @array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable temporal Array column was not materialized in this batch"))
      values.as(Slice(Array(T?)))
    end

    private def array_array_temporal_values_for(column : String, element_type : String, type : T.class) : Slice(Array(Array(T))) forall T
      index = column_index(column)
      unless WidePart.array_array_temporal_element_type(@column_types[index]).try { |actual| WidePart.same_temporal_leaf_family?(actual, element_type) } &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed temporal nested Array accessor requires an exact semantic temporal column")
      end
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("temporal nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(T))))
    end

    private def array_array_nullable_temporal_values_for(column : String, element_type : String, type : T.class) : Slice(Array(Array(T?))) forall T
      index = column_index(column)
      unless WidePart.array_array_nullable_temporal_element_type(@column_types[index]).try { |actual| WidePart.same_temporal_leaf_family?(actual, element_type) } &&
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
      raise UnsupportedFormatError.new("Decimal32 accessor requires Array(Array(Decimal(P, S))) with P in 1..9") unless WidePart.array_array_decimal32_scale(@column_types[index])
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal32 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int32))))
    end

    def array_array_decimal64_raw_for(column : String) : Slice(Array(Array(Int64)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires Array(Array(Decimal(P, S))) with P in 10..18") unless WidePart.array_array_decimal64_scale(@column_types[index])
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal64 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int64))))
    end

    def array_array_decimal128_raw_for(column : String) : Slice(Array(Array(Int128)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires Array(Array(Decimal(P, S))) with P in 19..38") unless WidePart.array_array_decimal128_scale(@column_types[index])
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal128 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int128))))
    end

    def array_array_decimal256_raw_for(column : String) : Slice(Array(Array(Decimal256Value)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal256 accessor requires Array(Array(Decimal(P, S))) with P in 39..76") unless WidePart.array_array_decimal256_scale(@column_types[index])
      values = @array_array_numeric_values[column]? || raise(UnsupportedFormatError.new("Decimal256 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Decimal256Value))))
    end

    def array_array_nullable_decimal32_raw_for(column : String) : Slice(Array(Array(Int32?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal32 accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 1..9") unless WidePart.array_array_nullable_decimal32_scale(@column_types[index])
      values = @array_array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal32 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int32?))))
    end

    def array_array_nullable_decimal64_raw_for(column : String) : Slice(Array(Array(Int64?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 10..18") unless WidePart.array_array_nullable_decimal64_scale(@column_types[index])
      values = @array_array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal64 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int64?))))
    end

    def array_array_nullable_decimal128_raw_for(column : String) : Slice(Array(Array(Int128?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 19..38") unless WidePart.array_array_nullable_decimal128_scale(@column_types[index])
      values = @array_array_nullable_numeric_values[column]? || raise(UnsupportedFormatError.new("nullable Decimal128 nested Array column was not materialized in this batch"))
      values.as(Slice(Array(Array(Int128?))))
    end

    def array_array_nullable_decimal256_raw_for(column : String) : Slice(Array(Array(Decimal256Value?)))
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal256 accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 39..76") unless WidePart.array_array_nullable_decimal256_scale(@column_types[index])
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

    # Return compositional Tuple row handles only for non-legacy W94 schemas.
    # The Slice aliases this callback batch; copy a row handle to retain it,
    # which also retains its owned mark backing independently.
    def tuple_rows_for(column : String) : Slice(WideTupleRow)
      index = column_index(column)
      type_name = @column_types[index]
      unless WideTupleTypePlan.for_type(type_name) && !WidePart.supports_tuple_uint64_string_type?(type_name)
        raise UnsupportedFormatError.new("Tuple row accessor requires a non-exact compositional Tuple column")
      end
      @tuple_row_values[column]? || raise(UnsupportedFormatError.new("compositional Tuple column was not materialized in this batch"))
    end

    # Return the per-outer-row handles for a generic named Array(Tuple)
    # profile. W51/W55 retain their established specialized accessors.
    def array_tuple_rows_for(column : String) : Slice(WideArrayTupleRow)
      index = column_index(column)
      type_name = @column_types[index]
      unless WideArrayTupleTypePlan.for_type(type_name) && WideTypePlan.admitted(type_name).nil?
        raise UnsupportedFormatError.new("Array(Tuple) row accessor requires a non-legacy admitted named Array(Tuple) column")
      end
      @array_tuple_row_values[column]? || raise(UnsupportedFormatError.new("Array(Tuple) column was not materialized in this batch"))
    end

    # Install a callback-batch slice after ordinary batch construction; this
    # preserves the long-standing constructor overloads and exact typed APIs.
    def install_array_tuple_rows(column : String, values : Slice(WideArrayTupleRow), expected_rows : Int)
      index = column_index(column)
      type_name = @column_types[index]
      unless WideArrayTupleTypePlan.for_type(type_name) && WideTypePlan.admitted(type_name).nil?
        raise UnsupportedFormatError.new("Array(Tuple) installation requires a non-legacy admitted named Array(Tuple) column")
      end
      raise CorruptPartError.new("selected Array(Tuple) row count differs from batch") unless values.size == expected_rows
      @array_tuple_row_values[column] = values
    end

    # Nominal Nested keeps its exact column type while reusing W107's owned
    # outer-row handles. Array(Tuple) accessors remain nominally Array-only.
    def nested_rows_for(column : String) : Slice(WideArrayTupleRow)
      index = column_index(column)
      unless WideNestedTypePlan.for_type(@column_types[index])
        raise UnsupportedFormatError.new("Nested row accessor requires an admitted nominal Nested column")
      end
      @array_tuple_row_values[column]? || raise(UnsupportedFormatError.new("Nested column was not materialized in this batch"))
    end

    def install_nested_rows(column : String, values : Slice(WideArrayTupleRow), expected_rows : Int) : Nil
      index = column_index(column)
      unless WideNestedTypePlan.for_type(@column_types[index])
        raise UnsupportedFormatError.new("Nested installation requires an admitted nominal Nested column")
      end
      raise CorruptPartError.new("selected Nested row count differs from batch") unless values.size == expected_rows
      @array_tuple_row_values[column] = values
    end

    # Return ordered Map-entry rows for a generic named Map(K, Tuple(...))
    # column. W84-specialized Map accessors retain their existing result types.
    def map_tuple_rows_for(column : String) : Slice(WideMapTupleRow)
      index = column_index(column)
      type_name = @column_types[index]
      unless WideMapTupleTypePlan.for_type(type_name) && WideTypePlan.admitted(type_name).nil?
        raise UnsupportedFormatError.new("Map(Tuple) row accessor requires a non-legacy admitted named Map(Tuple) column")
      end
      @map_tuple_row_values[column]? || raise(UnsupportedFormatError.new("Map(Tuple) column was not materialized in this batch"))
    end

    def install_map_tuple_rows(column : String, values : Slice(WideMapTupleRow), expected_rows : Int) : Nil
      index = column_index(column)
      type_name = @column_types[index]
      unless WideMapTupleTypePlan.for_type(type_name) && WideTypePlan.admitted(type_name).nil?
        raise UnsupportedFormatError.new("Map(Tuple) installation requires a non-legacy admitted named Map(Tuple) column")
      end
      raise CorruptPartError.new("selected Map(Tuple) row count differs from batch") unless values.size == expected_rows
      @map_tuple_row_values[column] = values
      nil
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

    def map_uint64_numeric_values_for(column : String, type : T.class) : Slice(Array(Tuple(UInt64, T))) forall T
      index = column_index(column)
      declared_value_type = WidePart.map_uint64_numeric_value_type(@column_types[index])
      requested_value_type = WidePart.numeric_type_name(type)
      unless declared_value_type == requested_value_type
        raise UnsupportedFormatError.new("Map(UInt64, T) accessor does not match the exact declared value type")
      end
      {% if T == UInt64 %}
        values = @map_uint64_uint64_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(UInt64, UInt64) column was not materialized in this batch"))
        return values.as(Slice(Array(Tuple(UInt64, T))))
      {% else %}
        values = @map_uint64_numeric_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(UInt64, T) column was not materialized in this batch"))
        values.as(WidePartNumericMapSlice(UInt64, T)).values
      {% end %}
    end

    def map_string_numeric_values_for(column : String, type : T.class) : Slice(Array(Tuple(String, T))) forall T
      index = column_index(column)
      declared_value_type = WidePart.map_string_numeric_value_type(@column_types[index])
      requested_value_type = WidePart.numeric_type_name(type)
      unless declared_value_type == requested_value_type
        raise UnsupportedFormatError.new("Map(String, T) accessor does not match the exact declared value type")
      end
      {% if T == UInt64 %}
        values = @map_string_uint64_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(String, UInt64) column was not materialized in this batch"))
        return values.as(Slice(Array(Tuple(String, T))))
      {% else %}
        values = @map_string_numeric_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(String, T) column was not materialized in this batch"))
        values.as(WidePartNumericMapSlice(String, T)).values
      {% end %}
    end

    def map_uint64_nullable_numeric_values_for(column : String, type : T.class) : Slice(Array(Tuple(UInt64, T?))) forall T
      index = column_index(column)
      declared_value_type = WidePart.map_uint64_nullable_numeric_value_type(@column_types[index])
      unless declared_value_type == WidePart.numeric_type_name(type)
        raise UnsupportedFormatError.new("Map(UInt64, Nullable(T)) accessor does not match the exact declared value type")
      end
      {% if T == UInt64 %}
        values = @map_uint64_nullable_uint64_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(UInt64, Nullable(UInt64)) column was not materialized in this batch"))
        values.as(Slice(Array(Tuple(UInt64, T?))))
      {% else %}
        values = @map_uint64_numeric_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(UInt64, Nullable(T)) column was not materialized in this batch"))
        values.as(WidePartNumericMapSlice(UInt64, T?)).values
      {% end %}
    end

    def map_string_nullable_numeric_values_for(column : String, type : T.class) : Slice(Array(Tuple(String, T?))) forall T
      index = column_index(column)
      declared_value_type = WidePart.map_string_nullable_numeric_value_type(@column_types[index])
      unless declared_value_type == WidePart.numeric_type_name(type)
        raise UnsupportedFormatError.new("Map(String, Nullable(T)) accessor does not match the exact declared value type")
      end
      {% if T == UInt64 %}
        values = @map_string_nullable_uint64_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(String, Nullable(UInt64)) column was not materialized in this batch"))
        values.as(Slice(Array(Tuple(String, T?))))
      {% else %}
        values = @map_string_numeric_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(String, Nullable(T)) column was not materialized in this batch"))
        values.as(WidePartNumericMapSlice(String, T?)).values
      {% end %}
    end

    def map_string_array_uint64s_for(column : String) : Slice(Array(Tuple(String, Array(UInt64))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(UInt64)) column") unless WidePart.supports_map_string_array_uint64_type?(@column_types[index])
      @map_string_array_uint64_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def array_map_string_uint64s_for(column : String) : Slice(Array(Array(Tuple(String, UInt64))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Map) accessor requires an exact Array(Map(String, UInt64)) column") unless @column_types[index] == "Array(Map(String, UInt64))"
      @array_map_string_uint64_values[column]? || raise(UnsupportedFormatError.new("Array(Map) column was not materialized in this batch"))
    end

    def array_map_uint64_strings_for(column : String) : Slice(Array(Array(Tuple(UInt64, String))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Map) accessor requires an exact Array(Map(UInt64, String)) column") unless @column_types[index] == "Array(Map(UInt64, String))"
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map) String leaf column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(UInt64, String)).values
    end

    def array_map_string_strings_for(column : String) : Slice(Array(Array(Tuple(String, String))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Map) accessor requires an exact Array(Map(String, String)) column") unless @column_types[index] == "Array(Map(String, String))"
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map) String leaf column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(String, String)).values
    end

    def array_map_uint64_nullable_strings_for(column : String) : Slice(Array(Array(Tuple(UInt64, String?))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Map) accessor requires an exact Array(Map(UInt64, Nullable(String))) column") unless @column_types[index] == "Array(Map(UInt64, Nullable(String)))"
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map) Nullable(String) leaf column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(UInt64, String?)).values
    end

    def array_map_string_nullable_strings_for(column : String) : Slice(Array(Array(Tuple(String, String?))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Map) accessor requires an exact Array(Map(String, Nullable(String))) column") unless @column_types[index] == "Array(Map(String, Nullable(String)))"
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map) Nullable(String) leaf column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(String, String?)).values
    end

    def array_map_uint64_bools_for(column : String) : Slice(Array(Array(Tuple(UInt64, Bool))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Map) accessor requires an exact Array(Map(UInt64, Bool)) column") unless @column_types[index] == "Array(Map(UInt64, Bool))"
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map) Bool leaf column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(UInt64, Bool)).values
    end

    def array_map_string_bools_for(column : String) : Slice(Array(Array(Tuple(String, Bool))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Map) accessor requires an exact Array(Map(String, Bool)) column") unless @column_types[index] == "Array(Map(String, Bool))"
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map) Bool leaf column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(String, Bool)).values
    end

    def array_map_uint64_nullable_bools_for(column : String) : Slice(Array(Array(Tuple(UInt64, Bool?))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Map) accessor requires an exact Array(Map(UInt64, Nullable(Bool))) column") unless @column_types[index] == "Array(Map(UInt64, Nullable(Bool)))"
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map) Nullable(Bool) leaf column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(UInt64, Bool?)).values
    end

    def array_map_string_nullable_bools_for(column : String) : Slice(Array(Array(Tuple(String, Bool?))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(Map) accessor requires an exact Array(Map(String, Nullable(Bool))) column") unless @column_types[index] == "Array(Map(String, Nullable(Bool)))"
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map) Nullable(Bool) leaf column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(String, Bool?)).values
    end

    def array_map_array_leaf_values_for(column : String, key_type : K.class, value_type : V.class) : Slice(Array(Array(Tuple(K, Array(V))))) forall K, V
      index = column_index(column)
      expected_key_type = key_type == String ? "String" : WidePart.numeric_type_name(key_type)
      expected_value_type = value_type == String ? "String" : WidePart.numeric_type_name(value_type)
      unless WidePart.array_map_array_leaf_shape(@column_types[index]) == {expected_key_type, expected_value_type}
        raise UnsupportedFormatError.new("Array(Map) accessor requires the exact W84 key and Array leaf types")
      end
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("W84 Array(Map) column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(K, Array(V))).values
    end

    def array_map_uint64_numeric_values_for(column : String, type : T.class) : Slice(Array(Array(Tuple(UInt64, T)))) forall T
      index = column_index(column)
      declared_value_type = WidePart.array_map_uint64_numeric_value_type(@column_types[index])
      unless declared_value_type == WidePart.numeric_type_name(type)
        raise UnsupportedFormatError.new("Array(Map(UInt64, T)) accessor does not match the exact declared value type")
      end
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map(UInt64, T)) column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(UInt64, T)).values
    end

    def array_map_string_numeric_values_for(column : String, type : T.class) : Slice(Array(Array(Tuple(String, T)))) forall T
      index = column_index(column)
      declared_value_type = WidePart.array_map_string_numeric_value_type(@column_types[index])
      unless declared_value_type == WidePart.numeric_type_name(type)
        raise UnsupportedFormatError.new("Array(Map(String, T)) accessor does not match the exact declared value type")
      end
      {% if T == UInt64 %}
        if values = @array_map_string_uint64_values[column]?
          return values.as(Slice(Array(Array(Tuple(String, T)))))
        end
      {% end %}
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map(String, T)) column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(String, T)).values
    end

    def array_map_uint64_nullable_numeric_values_for(column : String, type : T.class) : Slice(Array(Array(Tuple(UInt64, T?)))) forall T
      index = column_index(column)
      declared_value_type = WidePart.array_map_uint64_nullable_numeric_value_type(@column_types[index])
      unless declared_value_type == WidePart.numeric_type_name(type)
        raise UnsupportedFormatError.new("Array(Map(UInt64, Nullable(T))) accessor does not match the exact declared value type")
      end
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map(UInt64, Nullable(T))) column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(UInt64, T?)).values
    end

    def array_map_string_nullable_numeric_values_for(column : String, type : T.class) : Slice(Array(Array(Tuple(String, T?)))) forall T
      index = column_index(column)
      declared_value_type = WidePart.array_map_string_nullable_numeric_value_type(@column_types[index])
      unless declared_value_type == WidePart.numeric_type_name(type)
        raise UnsupportedFormatError.new("Array(Map(String, Nullable(T))) accessor does not match the exact declared value type")
      end
      values = @array_map_numeric_values[column]? || raise(UnsupportedFormatError.new("Array(Map(String, Nullable(T))) column was not materialized in this batch"))
      values.as(WidePartArrayMapNumericSlice(String, T?)).values
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

    def map_uint64_array_nullable_strings_for(column : String) : Slice(Array(Tuple(UInt64, Array(String?))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Array(Nullable(String))) column") unless WidePart.supports_map_uint64_array_nullable_string_type?(@column_types[index])
      @map_uint64_array_nullable_string_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_uint64_array_uint64s_for(column : String) : Slice(Array(Tuple(UInt64, Array(UInt64))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Array(UInt64)) column") unless WidePart.supports_map_uint64_array_uint64_type?(@column_types[index])
      @map_uint64_array_uint64_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_string_array_strings_for(column : String) : Slice(Array(Tuple(String, Array(String))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(String)) column") unless WidePart.supports_map_string_array_string_type?(@column_types[index])
      @map_string_array_string_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_uint64_array_strings_for(column : String) : Slice(Array(Tuple(UInt64, Array(String))))
      index = column_index(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Array(String)) column") unless WidePart.supports_map_uint64_array_string_type?(@column_types[index])
      @map_uint64_array_string_values[column]? || raise(UnsupportedFormatError.new("Map column was not materialized in this batch"))
    end

    def map_uint64_array_numeric_values_for(column : String, type : T.class) : Slice(Array(Tuple(UInt64, Array(T)))) forall T
      index = column_index(column)
      declared = WidePart.map_uint64_array_numeric_value_type(@column_types[index])
      unless declared == WidePart.numeric_type_name(type)
        raise UnsupportedFormatError.new("Map(UInt64, Array(T)) accessor does not match the exact declared leaf type")
      end
      {% if T == UInt64 %}
        values = @map_uint64_array_uint64_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(UInt64, Array(UInt64)) column was not materialized in this batch"))
        values.as(Slice(Array(Tuple(UInt64, Array(T)))))
      {% else %}
        values = @map_uint64_numeric_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(UInt64, Array(T)) column was not materialized in this batch"))
        values.as(WidePartNumericMapSlice(UInt64, Array(T))).values
      {% end %}
    end

    def map_string_array_numeric_values_for(column : String, type : T.class) : Slice(Array(Tuple(String, Array(T)))) forall T
      index = column_index(column)
      declared = WidePart.map_string_array_numeric_value_type(@column_types[index])
      unless declared == WidePart.numeric_type_name(type)
        raise UnsupportedFormatError.new("Map(String, Array(T)) accessor does not match the exact declared leaf type")
      end
      {% if T == UInt64 %}
        values = @map_string_array_uint64_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(String, Array(UInt64)) column was not materialized in this batch"))
        values.as(Slice(Array(Tuple(String, Array(T)))))
      {% else %}
        values = @map_string_numeric_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(String, Array(T)) column was not materialized in this batch"))
        values.as(WidePartNumericMapSlice(String, Array(T))).values
      {% end %}
    end

    def map_uint64_array_nullable_numeric_values_for(column : String, type : T.class) : Slice(Array(Tuple(UInt64, Array(T?)))) forall T
      index = column_index(column)
      declared = WidePart.map_uint64_array_nullable_numeric_value_type(@column_types[index])
      unless declared == WidePart.numeric_type_name(type)
        raise UnsupportedFormatError.new("Map(UInt64, Array(Nullable(T))) accessor does not match the exact declared leaf type")
      end
      {% if T == UInt64 %}
        values = @map_uint64_array_nullable_uint64_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(UInt64, Array(Nullable(UInt64))) column was not materialized in this batch"))
        values.as(Slice(Array(Tuple(UInt64, Array(T?)))))
      {% else %}
        values = @map_uint64_numeric_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(UInt64, Array(Nullable(T))) column was not materialized in this batch"))
        values.as(WidePartNumericMapSlice(UInt64, Array(T?))).values
      {% end %}
    end

    def map_string_array_nullable_numeric_values_for(column : String, type : T.class) : Slice(Array(Tuple(String, Array(T?)))) forall T
      index = column_index(column)
      declared = WidePart.map_string_array_nullable_numeric_value_type(@column_types[index])
      unless declared == WidePart.numeric_type_name(type)
        raise UnsupportedFormatError.new("Map(String, Array(Nullable(T))) accessor does not match the exact declared leaf type")
      end
      {% if T == UInt64 %}
        values = @map_string_array_nullable_uint64_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(String, Array(Nullable(UInt64))) column was not materialized in this batch"))
        values.as(Slice(Array(Tuple(String, Array(T?)))))
      {% else %}
        values = @map_string_numeric_values[column]? ||
                 raise(UnsupportedFormatError.new("Map(String, Array(Nullable(T))) column was not materialized in this batch"))
        values.as(WidePartNumericMapSlice(String, Array(T?))).values
      {% end %}
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
      datetime_type = DateTimeColumnType.parse(@column_types[index])
      raise UnsupportedFormatError.new("Nullable(DateTime) accessor requires an exact Nullable(DateTime) column") unless datetime_type && datetime_type.shape == DateTimeColumnType::Shape::Nullable && datetime_type.family == DateTimeColumnType::Family::DateTime
      @nullable_values[column]?.try(&.as(Slice(UInt32?))) || raise(UnsupportedFormatError.new("Nullable(DateTime) column was not materialized in this batch"))
    end

    def nullable_datetime64_ticks_for(column : String) : Slice(Int64?)
      index = column_index(column)
      unless WidePart.nullable_datetime64_scale(@column_types[index])
        raise UnsupportedFormatError.new("Nullable(DateTime64) accessor requires a canonical Nullable(DateTime64(p)) column")
      end
      @nullable_values[column]?.try(&.as(Slice(Int64?))) || raise(UnsupportedFormatError.new("Nullable(DateTime64) column was not materialized in this batch"))
    end

    def nullable_interval_counts_for(column : String) : Slice(Int64?)
      index = column_index(column)
      interval_type = IntervalColumnType.parse(@column_types[index])
      unless interval_type && interval_type.shape == IntervalColumnType::Shape::Nullable
        raise UnsupportedFormatError.new("Interval accessor requires an exact Nullable(Interval) column")
      end
      @nullable_values[column]?.try(&.as(Slice(Int64?))) || raise(UnsupportedFormatError.new("Nullable(Interval) column was not materialized in this batch"))
    end

    def nullable_simple_aggregate_uint64s_for(column : String) : Slice(UInt64?)
      index = column_index(column)
      aggregate_type = SimpleAggregateColumnType.parse(@column_types[index])
      unless aggregate_type && aggregate_type.shape == SimpleAggregateColumnType::Shape::Nullable && aggregate_type.storage_type_name == "UInt64"
        raise UnsupportedFormatError.new("SimpleAggregateFunction accessor requires an exact Nullable scalar UInt64 profile")
      end
      @nullable_values[column]?.try(&.as(Slice(UInt64?))) || raise(UnsupportedFormatError.new("Nullable SimpleAggregateFunction column was not materialized in this batch"))
    end

    # Nullable batch values preserve NULL independently from their exact raw
    # carrier, and reject same-width aliases before any cast is attempted.
    def nullable_simple_aggregate_values_for(column : String, type : T.class) : Slice(T?) forall T
      index = column_index(column)
      aggregate_type = SimpleAggregateColumnType.parse(@column_types[index])
      expected_storage = SimpleAggregateColumnType.storage_name(type)
      unless aggregate_type && aggregate_type.shape == SimpleAggregateColumnType::Shape::Nullable && aggregate_type.storage_type_name == expected_storage
        raise UnsupportedFormatError.new("typed Nullable SimpleAggregateFunction accessor does not match selected carrier")
      end
      @nullable_values[column]?.try(&.as(Slice(T?))) || raise(UnsupportedFormatError.new("Nullable SimpleAggregateFunction column was not materialized in this batch"))
    end

    def nullable_simple_aggregate_decimal32_raw_for(column : String, function : BinarySimpleAggregateType::Function, precision : Int32, scale : Int32) : Slice(Int32?)
      index = column_index(column)
      plan = SimpleAggregateDecimalStoragePlan.require(@column_types[index], function, precision, scale, true)
      plan.validate_carrier!(Int32)
      @nullable_values[column]?.try(&.as(Slice(Int32?))) || raise(UnsupportedFormatError.new("Nullable Decimal SimpleAggregateFunction column was not materialized in this batch"))
    end

    def nullable_simple_aggregate_decimal64_raw_for(column : String, function : BinarySimpleAggregateType::Function, precision : Int32, scale : Int32) : Slice(Int64?)
      index = column_index(column)
      plan = SimpleAggregateDecimalStoragePlan.require(@column_types[index], function, precision, scale, true)
      plan.validate_carrier!(Int64)
      @nullable_values[column]?.try(&.as(Slice(Int64?))) || raise(UnsupportedFormatError.new("Nullable Decimal SimpleAggregateFunction column was not materialized in this batch"))
    end

    def nullable_simple_aggregate_decimal128_raw_for(column : String, function : BinarySimpleAggregateType::Function, precision : Int32, scale : Int32) : Slice(Int128?)
      index = column_index(column)
      plan = SimpleAggregateDecimalStoragePlan.require(@column_types[index], function, precision, scale, true)
      plan.validate_carrier!(Int128)
      @nullable_values[column]?.try(&.as(Slice(Int128?))) || raise(UnsupportedFormatError.new("Nullable Decimal SimpleAggregateFunction column was not materialized in this batch"))
    end

    def nullable_simple_aggregate_decimal256_raw_for(column : String, function : BinarySimpleAggregateType::Function, precision : Int32, scale : Int32) : Slice(Decimal256Value?)
      index = column_index(column)
      plan = SimpleAggregateDecimalStoragePlan.require(@column_types[index], function, precision, scale, true)
      plan.validate_carrier!(Decimal256Value)
      @nullable_values[column]?.try(&.as(Slice(Decimal256Value?))) || raise(UnsupportedFormatError.new("Nullable Decimal SimpleAggregateFunction column was not materialized in this batch"))
    end

    def nullable_simple_aggregate_temporal_raw_values_for(
      column : String,
      function : BinarySimpleAggregateType::Function,
      storage_type_name : String,
      type : T.class,
    ) : Slice(T?) forall T
      index = column_index(column)
      plan = SimpleAggregateTemporalStoragePlan.require(@column_types[index], function, storage_type_name, true)
      plan.validate_carrier!(type)
      @nullable_values[column]?.try(&.as(Slice(T?))) || raise(UnsupportedFormatError.new("Nullable temporal SimpleAggregateFunction column was not materialized in this batch"))
    end

    def nullable_simple_aggregate_strings_for(column : String) : Slice(String?)
      index = column_index(column)
      plan = SimpleAggregateTextStoragePlan.for_type_name(@column_types[index])
      unless plan && plan.nullable? && plan.variable_string?
        raise UnsupportedFormatError.new("SimpleAggregateFunction accessor requires exact outer Nullable String storage")
      end
      @nullable_string_values[column]? || raise(UnsupportedFormatError.new("Nullable SimpleAggregateFunction(String) column was not materialized in this batch"))
    end

    def nullable_simple_aggregate_fixed_strings_for(column : String) : Slice(String?)
      index = column_index(column)
      plan = SimpleAggregateTextStoragePlan.for_type_name(@column_types[index])
      unless plan && plan.nullable? && !plan.fixed_string_width.nil?
        raise UnsupportedFormatError.new("SimpleAggregateFunction accessor requires exact outer Nullable FixedString(N) storage")
      end
      @nullable_fixed_string_values[column]? || raise(UnsupportedFormatError.new("Nullable SimpleAggregateFunction(FixedString) column was not materialized in this batch"))
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
end
