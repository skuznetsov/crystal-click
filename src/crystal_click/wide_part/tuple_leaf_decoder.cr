module CrystalClick
  class WidePart
    # Shared scalar/Nullable leaf codec dispatch for Tuple values and Map
    # keys. The existing family-specific decoders remain owned by WidePart.
    private class TupleLeafDecoder
      alias DecodeNumericLeaf = Proc(String, String, Bytes, UInt64, Int32, WideTupleLeafColumn)
      alias DecodeBoolLeaf = Proc(String, Bytes, UInt64, Int32, WideTupleLeafColumn)
      alias DecodeIdentifierLeaf = Proc(String, String, Bytes, UInt64, Int32, WideTupleLeafColumn)
      alias DecodeTemporalLeaf = Proc(String, String, Bytes, UInt64, Int32, WideTupleLeafColumn)
      alias DecodeDateTimeLeaf = Proc(String, DateTimeColumnType, Bytes, UInt64, Int32, WideTupleLeafColumn)
      alias DecodeParameterizedLeaf = Proc(String, WideTupleParameterizedType, Bytes, UInt64, Int32, WideTupleLeafColumn)
      alias DecodeNullableLeaf = Proc(String, WideTupleLeafType, Bytes, ScalarNullMap, UInt64, Int32, WideTupleLeafColumn)

      @decode_numeric_leaf : DecodeNumericLeaf
      @decode_bool_leaf : DecodeBoolLeaf
      @decode_identifier_leaf : DecodeIdentifierLeaf
      @decode_temporal_leaf : DecodeTemporalLeaf
      @decode_datetime_leaf : DecodeDateTimeLeaf
      @decode_parameterized_leaf : DecodeParameterizedLeaf
      @decode_nullable_leaf : DecodeNullableLeaf

      def initialize(
        @decode_numeric_leaf : DecodeNumericLeaf,
        @decode_bool_leaf : DecodeBoolLeaf,
        @decode_identifier_leaf : DecodeIdentifierLeaf,
        @decode_temporal_leaf : DecodeTemporalLeaf,
        @decode_datetime_leaf : DecodeDateTimeLeaf,
        @decode_parameterized_leaf : DecodeParameterizedLeaf,
        @decode_nullable_leaf : DecodeNullableLeaf,
      )
      end

      def decode_nullable(
        field : WideTupleField,
        bytes : Bytes,
        null_map : ScalarNullMap,
        rows : UInt64,
        width : Int32,
      ) : WideTupleLeafColumn
        @decode_nullable_leaf.call(field.name, field.leaf_type, bytes, null_map, rows, width)
      end

      def decode_fixed(
        field : WideTupleField,
        bytes : Bytes,
        rows : UInt64,
        width : Int32,
      ) : WideTupleLeafColumn
        leaf_type = field.leaf_type
        if exact_type = field.parameterized_type
          @decode_parameterized_leaf.call(field.name, exact_type, bytes, rows, width)
        elsif exact_type = field.datetime_type
          @decode_datetime_leaf.call(field.name, exact_type, bytes, rows, width)
        elsif leaf_type.base_type_name == "Bool"
          @decode_bool_leaf.call(field.name, bytes, rows, width)
        elsif WideTupleIdentifierType.width(leaf_type.base_type_name)
          @decode_identifier_leaf.call(field.name, leaf_type.base_type_name, bytes, rows, width)
        elsif WideTupleTemporalType.width(leaf_type.base_type_name)
          @decode_temporal_leaf.call(field.name, leaf_type.base_type_name, bytes, rows, width)
        elsif WideTupleNumericType.width(leaf_type.base_type_name)
          @decode_numeric_leaf.call(field.name, leaf_type.base_type_name, bytes, rows, width)
        else
          raise UnsupportedFormatError.new("unsupported fixed-width Tuple leaf type")
        end
      end
    end
  end
end
