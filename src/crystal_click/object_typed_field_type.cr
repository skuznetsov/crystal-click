module CrystalClick
  # Closed nominal type policy for Object JSON typed fields. The static names
  # are also used during budget preflight so callers do not allocate a
  # BinaryDataType name before the declaration has been admitted.
  module ObjectTypedFieldType
    TYPE_NAMES = {
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
      {BinaryDataType::TAG_BOOL, "Bool"},
      {BinaryDataType::TAG_STRING, "String"},
    }

    def self.name_for(type : BinaryDataType) : String?
      name_for_tag(type.tag)
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
