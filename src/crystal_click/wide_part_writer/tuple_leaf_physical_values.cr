module CrystalClick
  module WidePartWriter
    # Compares owned pre-stage and staged physical carriers without passing
    # through nullable logical values or normalizing floating/decimal bits.
    private class TupleLeafPhysicalValues
      def self.matches?(
        expected : WideTupleLeafColumn::Buffer,
        actual : WideTupleLeafColumn::Buffer,
      ) : Bool
        return false unless expected.size == actual.size

        case expected
        when Array(String)
          values = actual.as?(Array(String)) || return false
          expected.each_with_index { |value, index| return false unless value == values[index] }
        when Array(Bool)
          values = actual.as?(Array(Bool)) || return false
          expected.each_with_index { |value, index| return false unless value == values[index] }
        when Array(UUIDValue)
          values = actual.as?(Array(UUIDValue)) || return false
          expected.each_with_index do |value, index|
            return false unless WideTupleIdentifierType.same_bits?(value, values[index])
          end
        when Array(IPv4Value)
          values = actual.as?(Array(IPv4Value)) || return false
          expected.each_with_index do |value, index|
            return false unless WideTupleIdentifierType.same_bits?(value, values[index])
          end
        when Array(IPv6Value)
          values = actual.as?(Array(IPv6Value)) || return false
          expected.each_with_index do |value, index|
            return false unless WideTupleIdentifierType.same_bits?(value, values[index])
          end
        when Array(DateValue)
          values = actual.as?(Array(DateValue)) || return false
          expected.each_with_index do |value, index|
            return false unless WideTupleTemporalType.same_bits?(value, values[index])
          end
        when Array(Date32Value)
          values = actual.as?(Array(Date32Value)) || return false
          expected.each_with_index do |value, index|
            return false unless WideTupleTemporalType.same_bits?(value, values[index])
          end
        when Array(DateTimeValue)
          values = actual.as?(Array(DateTimeValue)) || return false
          expected.each_with_index do |value, index|
            return false unless WideTupleTemporalType.same_bits?(value, values[index])
          end
        when Array(DateTime64Value)
          values = actual.as?(Array(DateTime64Value)) || return false
          expected.each_with_index do |value, index|
            return false unless WideTupleTemporalType.same_bits?(value, values[index])
          end
        when Array(TimeValue)
          values = actual.as?(Array(TimeValue)) || return false
          expected.each_with_index do |value, index|
            return false unless WideTupleTemporalType.same_bits?(value, values[index])
          end
        when Array(Time64Value)
          values = actual.as?(Array(Time64Value)) || return false
          expected.each_with_index do |value, index|
            return false unless WideTupleTemporalType.same_bits?(value, values[index])
          end
        when Array(FixedStringValue)
          values = actual.as?(Array(FixedStringValue)) || return false
          expected.each_with_index do |value, index|
            other = values[index]
            return false unless value.width == other.width && value.raw_bytes == other.raw_bytes
          end
        when Array(Enum8Value)
          values = actual.as?(Array(Enum8Value)) || return false
          expected.each_with_index { |value, index| return false unless value == values[index] }
        when Array(Enum16Value)
          values = actual.as?(Array(Enum16Value)) || return false
          expected.each_with_index { |value, index| return false unless value == values[index] }
        when Array(Decimal32Value)
          values = actual.as?(Array(Decimal32Value)) || return false
          expected.each_with_index { |value, index| return false unless value == values[index] }
        when Array(Decimal64Value)
          values = actual.as?(Array(Decimal64Value)) || return false
          expected.each_with_index { |value, index| return false unless value == values[index] }
        when Array(Decimal128Value)
          values = actual.as?(Array(Decimal128Value)) || return false
          expected.each_with_index { |value, index| return false unless value == values[index] }
        when Array(Decimal256TupleValue)
          values = actual.as?(Array(Decimal256TupleValue)) || return false
          expected.each_with_index { |value, index| return false unless value == values[index] }
        else
          expected_numeric = expected.as?(WideTupleNumericType::Buffer) || return false
          actual_numeric = actual.as?(WideTupleNumericType::Buffer) || return false
          return false unless WideTupleNumericType.type_name_for_buffer(expected_numeric) ==
                                WideTupleNumericType.type_name_for_buffer(actual_numeric)
          expected_numeric.each_with_index do |value, index|
            return false unless WideTupleNumericType.same_bits?(value, actual_numeric[index])
          end
        end
        true
      end

      def self.staged_mismatch_message(leaf_type : WideTupleLeafType) : String
        if parameterized_type = leaf_type.parameterized_type
          case parameterized_type
          when WideTupleFixedStringType then "staged Tuple FixedString leaf readback differs"
          when WideTupleEnumType        then "staged Tuple Enum leaf readback differs"
          when WideTupleDecimalType     then "staged Tuple Decimal leaf readback differs"
          else                               "staged Tuple parameterized leaf readback differs"
          end
        else
          base_type = leaf_type.base_type_name
          if base_type == "String"
            "staged Tuple String leaf readback differs"
          elsif base_type == "Bool"
            "staged Tuple Bool leaf readback differs"
          elsif base_type == "UInt64"
            "staged Tuple UInt64 leaf readback differs"
          elsif WideTupleIdentifierType.width(base_type)
            "staged Tuple identifier leaf readback differs"
          elsif WideTupleTemporalType.width(base_type)
            "staged Tuple temporal leaf readback differs"
          else
            "staged Tuple numeric leaf readback differs"
          end
        end
      end
    end
  end
end
