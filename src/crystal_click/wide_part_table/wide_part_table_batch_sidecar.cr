module CrystalClick
  # Concrete union for values installed by BinaryValueTypedBatchAdapter.
  # Crystal cannot store Reference as a generic type argument; this keeps the
  # exact carrier owners alive without erasing their types.
  alias BinaryValueTypedBatchOwner = Array(UInt64) |
                                     Array(String) |
                                     Array(UInt64?) |
                                     Array(Array(UInt64?)) |
                                     Array(VariantStringUInt64Value) |
                                     Array(Tuple(UInt64, String)) |
                                     Array(Array(Tuple(UInt64, String))) |
                                     Array(Array(Tuple(String, UInt64))) |
                                     Array(Array(Tuple(String, Array(UInt64?)))) |
                                     Array(WideTupleRow) |
                                     Array(WideArrayTupleRow)

  # :nodoc:
  # Internal maps and owners retained by typed Wide callback batches.
  # UInt64-only windows leave this owner absent until one is requested.
  private struct WidePartTableBatchSidecar
    getter typed_numeric_values : Hash(String, WidePartNumericSlice)
    getter qbit_values : Hash(String, Slice(QBitValue))
    getter point_values : Hash(String, Slice(WidePointValue))
    getter geo_array_rows : Hash(String, Slice(WideGeoArrayRow))
    getter geometry_rows : Hash(String, Slice(WideGeometryRow))
    getter object_documents : Hash(String, Slice(ObjectDocument))
    getter array_object_documents : Hash(String, Slice(Array(ObjectDocument)))
    getter recursive_values : Hash(String, Slice(StorageColumnValue))
    getter binary_bulk_values : Hash(String, Slice(BinaryValue))
    getter nullable_qbit_values : Hash(String, Slice(QBitValue?))
    getter aggregate_count_state_values : Hash(String, Slice(BinaryValue))
    getter string_values : Hash(String, Slice(String))
    getter fixed_string_values : Hash(String, Slice(String))
    getter nullable_values : Hash(String, WidePartNullableSlice)
    getter nullable_string_values : Hash(String, WidePartNullableStringSlice)
    getter nullable_fixed_string_values : Hash(String, WidePartNullableStringSlice)
    getter array_uint64_values : Hash(String, Slice(Array(UInt64)))
    getter array_nullable_uint64_values : Hash(String, Slice(Array(UInt64?)))
    getter array_string_values : Hash(String, Slice(Array(String)))
    getter array_nullable_string_values : Hash(String, WidePartArrayNullableStringSlice)
    getter array_array_uint64_values : Hash(String, Slice(Array(Array(UInt64))))
    getter array_array_string_values : Hash(String, Slice(Array(Array(String))))
    getter array_array_nullable_string_values : Hash(String, WidePartArrayArrayNullableStringSlice)
    getter array_array_nullable_uint64_values : Hash(String, Slice(Array(Array(UInt64?))))
    getter array_array_numeric_values : Hash(String, WidePartArrayArrayNumericSlice)
    getter array_array_nullable_numeric_values : Hash(String, WidePartArrayArrayNullableNumericSlice)
    getter array_numeric_values : Hash(String, WidePartArrayNumericSlice)
    getter array_nullable_numeric_values : Hash(String, WidePartArrayNullableNumericSlice)
    getter array_bool_values : Hash(String, WidePartArrayBoolSlice)
    getter array_nullable_bool_values : Hash(String, WidePartArrayNullableBoolSlice)
    getter array_tuple_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64, String))))
    getter array_tuple_nullable_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64?, String))))
    getter array_tuple_uint64_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64))))
    getter variant_string_uint64_values : Hash(String, Slice(VariantStringUInt64Value))
    getter variant_bool_string_uint64_values : Hash(String, Slice(VariantBoolStringUInt64Value))
    getter tuple_string_values : Hash(String, Slice(Tuple(UInt64, String)))
    getter tuple_row_values : Hash(String, Slice(WideTupleRow))
    getter array_tuple_row_values : Hash(String, Slice(WideArrayTupleRow))
    getter map_tuple_row_values : Hash(String, Slice(WideMapTupleRow))
    getter map_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64, String))))
    getter map_uint64_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64))))
    getter map_string_uint64_values : Hash(String, Slice(Array(Tuple(String, UInt64))))
    getter map_string_array_uint64_values : Hash(String, Slice(Array(Tuple(String, Array(UInt64)))))
    getter array_map_string_uint64_values : Hash(String, Slice(Array(Array(Tuple(String, UInt64)))))
    getter array_map_numeric_values : Hash(String, WidePartArrayMapNumericSliceBase)
    getter map_string_array_nullable_uint64_values : Hash(String, Slice(Array(Tuple(String, Array(UInt64?)))))
    getter map_string_array_nullable_string_values : Hash(String, Slice(Array(Tuple(String, Array(String?)))))
    getter map_uint64_array_nullable_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?)))))
    getter map_uint64_array_nullable_string_values : Hash(String, Slice(Array(Tuple(UInt64, Array(String?)))))
    getter map_uint64_array_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64)))))
    getter map_string_array_string_values : Hash(String, Slice(Array(Tuple(String, Array(String)))))
    getter map_uint64_array_string_values : Hash(String, Slice(Array(Tuple(UInt64, Array(String)))))
    getter map_string_string_values : Hash(String, Slice(Array(Tuple(String, String))))
    getter map_uint64_nullable_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64?))))
    getter map_string_nullable_uint64_values : Hash(String, Slice(Array(Tuple(String, UInt64?))))
    getter map_uint64_nullable_string_values : Hash(String, Slice(Array(Tuple(UInt64, String?))))
    getter map_string_nullable_string_values : Hash(String, Slice(Array(Tuple(String, String?))))
    getter map_uint64_numeric_values : Hash(String, WidePartNumericMapSliceBase)
    getter map_string_numeric_values : Hash(String, WidePartNumericMapSliceBase)
    getter binary_value_typed_owners : Array(BinaryValueTypedBatchOwner)

    def initialize(
      @typed_numeric_values : Hash(String, WidePartNumericSlice) = Hash(String, WidePartNumericSlice).new,
      @qbit_values : Hash(String, Slice(QBitValue)) = Hash(String, Slice(QBitValue)).new,
      @point_values : Hash(String, Slice(WidePointValue)) = Hash(String, Slice(WidePointValue)).new,
      @geo_array_rows : Hash(String, Slice(WideGeoArrayRow)) = Hash(String, Slice(WideGeoArrayRow)).new,
      @geometry_rows : Hash(String, Slice(WideGeometryRow)) = Hash(String, Slice(WideGeometryRow)).new,
      @object_documents : Hash(String, Slice(ObjectDocument)) = Hash(String, Slice(ObjectDocument)).new,
      @array_object_documents : Hash(String, Slice(Array(ObjectDocument))) = Hash(String, Slice(Array(ObjectDocument))).new,
      @recursive_values : Hash(String, Slice(StorageColumnValue)) = Hash(String, Slice(StorageColumnValue)).new,
      @binary_bulk_values : Hash(String, Slice(BinaryValue)) = Hash(String, Slice(BinaryValue)).new,
      @nullable_qbit_values : Hash(String, Slice(QBitValue?)) = Hash(String, Slice(QBitValue?)).new,
      @aggregate_count_state_values : Hash(String, Slice(BinaryValue)) = Hash(String, Slice(BinaryValue)).new,
      @string_values : Hash(String, Slice(String)) = Hash(String, Slice(String)).new,
      @fixed_string_values : Hash(String, Slice(String)) = Hash(String, Slice(String)).new,
      @nullable_values : Hash(String, WidePartNullableSlice) = Hash(String, WidePartNullableSlice).new,
      @nullable_string_values : Hash(String, WidePartNullableStringSlice) = Hash(String, WidePartNullableStringSlice).new,
      @nullable_fixed_string_values : Hash(String, WidePartNullableStringSlice) = Hash(String, WidePartNullableStringSlice).new,
      @array_uint64_values : Hash(String, Slice(Array(UInt64))) = Hash(String, Slice(Array(UInt64))).new,
      @array_nullable_uint64_values : Hash(String, Slice(Array(UInt64?))) = Hash(String, Slice(Array(UInt64?))).new,
      @array_string_values : Hash(String, Slice(Array(String))) = Hash(String, Slice(Array(String))).new,
      @array_nullable_string_values : Hash(String, WidePartArrayNullableStringSlice) = Hash(String, WidePartArrayNullableStringSlice).new,
      @array_array_uint64_values : Hash(String, Slice(Array(Array(UInt64)))) = Hash(String, Slice(Array(Array(UInt64)))).new,
      @array_array_string_values : Hash(String, Slice(Array(Array(String)))) = Hash(String, Slice(Array(Array(String)))).new,
      @array_array_nullable_string_values : Hash(String, WidePartArrayArrayNullableStringSlice) = Hash(String, WidePartArrayArrayNullableStringSlice).new,
      @array_array_nullable_uint64_values : Hash(String, Slice(Array(Array(UInt64?)))) = Hash(String, Slice(Array(Array(UInt64?)))).new,
      @array_array_numeric_values : Hash(String, WidePartArrayArrayNumericSlice) = Hash(String, WidePartArrayArrayNumericSlice).new,
      @array_array_nullable_numeric_values : Hash(String, WidePartArrayArrayNullableNumericSlice) = Hash(String, WidePartArrayArrayNullableNumericSlice).new,
      @array_numeric_values : Hash(String, WidePartArrayNumericSlice) = Hash(String, WidePartArrayNumericSlice).new,
      @array_nullable_numeric_values : Hash(String, WidePartArrayNullableNumericSlice) = Hash(String, WidePartArrayNullableNumericSlice).new,
      @array_bool_values : Hash(String, WidePartArrayBoolSlice) = Hash(String, WidePartArrayBoolSlice).new,
      @array_nullable_bool_values : Hash(String, WidePartArrayNullableBoolSlice) = Hash(String, WidePartArrayNullableBoolSlice).new,
      @array_tuple_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64, String)))) = Hash(String, Slice(Array(Tuple(UInt64, String)))).new,
      @array_tuple_nullable_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64?, String)))) = Hash(String, Slice(Array(Tuple(UInt64?, String)))).new,
      @array_tuple_uint64_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64)))) = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new,
      @variant_string_uint64_values : Hash(String, Slice(VariantStringUInt64Value)) = Hash(String, Slice(VariantStringUInt64Value)).new,
      @variant_bool_string_uint64_values : Hash(String, Slice(VariantBoolStringUInt64Value)) = Hash(String, Slice(VariantBoolStringUInt64Value)).new,
      @tuple_string_values : Hash(String, Slice(Tuple(UInt64, String))) = Hash(String, Slice(Tuple(UInt64, String))).new,
      @tuple_row_values : Hash(String, Slice(WideTupleRow)) = Hash(String, Slice(WideTupleRow)).new,
      @array_tuple_row_values : Hash(String, Slice(WideArrayTupleRow)) = Hash(String, Slice(WideArrayTupleRow)).new,
      @map_tuple_row_values : Hash(String, Slice(WideMapTupleRow)) = Hash(String, Slice(WideMapTupleRow)).new,
      @map_uint64_string_values : Hash(String, Slice(Array(Tuple(UInt64, String)))) = Hash(String, Slice(Array(Tuple(UInt64, String)))).new,
      @map_uint64_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64)))) = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new,
      @map_string_uint64_values : Hash(String, Slice(Array(Tuple(String, UInt64)))) = Hash(String, Slice(Array(Tuple(String, UInt64)))).new,
      @map_string_array_uint64_values : Hash(String, Slice(Array(Tuple(String, Array(UInt64))))) = Hash(String, Slice(Array(Tuple(String, Array(UInt64))))).new,
      @array_map_string_uint64_values : Hash(String, Slice(Array(Array(Tuple(String, UInt64))))) = Hash(String, Slice(Array(Array(Tuple(String, UInt64))))).new,
      @array_map_numeric_values : Hash(String, WidePartArrayMapNumericSliceBase) = Hash(String, WidePartArrayMapNumericSliceBase).new,
      @map_string_array_nullable_uint64_values : Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))) = Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))).new,
      @map_string_array_nullable_string_values : Hash(String, Slice(Array(Tuple(String, Array(String?))))) = Hash(String, Slice(Array(Tuple(String, Array(String?))))).new,
      @map_uint64_array_nullable_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))) = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))).new,
      @map_uint64_array_nullable_string_values : Hash(String, Slice(Array(Tuple(UInt64, Array(String?))))) = Hash(String, Slice(Array(Tuple(UInt64, Array(String?))))).new,
      @map_uint64_array_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64))))) = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64))))).new,
      @map_string_array_string_values : Hash(String, Slice(Array(Tuple(String, Array(String))))) = Hash(String, Slice(Array(Tuple(String, Array(String))))).new,
      @map_uint64_array_string_values : Hash(String, Slice(Array(Tuple(UInt64, Array(String))))) = Hash(String, Slice(Array(Tuple(UInt64, Array(String))))).new,
      @map_string_string_values : Hash(String, Slice(Array(Tuple(String, String)))) = Hash(String, Slice(Array(Tuple(String, String)))).new,
      @map_uint64_nullable_uint64_values : Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))) = Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))).new,
      @map_string_nullable_uint64_values : Hash(String, Slice(Array(Tuple(String, UInt64?)))) = Hash(String, Slice(Array(Tuple(String, UInt64?)))).new,
      @map_uint64_nullable_string_values : Hash(String, Slice(Array(Tuple(UInt64, String?)))) = Hash(String, Slice(Array(Tuple(UInt64, String?)))).new,
      @map_string_nullable_string_values : Hash(String, Slice(Array(Tuple(String, String?)))) = Hash(String, Slice(Array(Tuple(String, String?)))).new,
      @map_uint64_numeric_values : Hash(String, WidePartNumericMapSliceBase) = Hash(String, WidePartNumericMapSliceBase).new,
      @map_string_numeric_values : Hash(String, WidePartNumericMapSliceBase) = Hash(String, WidePartNumericMapSliceBase).new,
      @binary_value_typed_owners : Array(BinaryValueTypedBatchOwner) = [] of BinaryValueTypedBatchOwner,
    )
    end
  end
end
