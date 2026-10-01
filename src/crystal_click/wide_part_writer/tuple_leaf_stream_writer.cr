module CrystalClick
  module WidePartWriter
    # One family dispatch for flat and ragged Tuple streams. The exact leaf
    # descriptor supplies nominal metadata; schedule changes only mark rows
    # and the flattened leaf interval, never the physical codec.
    private class TupleLeafStreamWriter
      def self.write(
        stage : String,
        value_name : String,
        type_plan : WideTupleTypePlan,
        fields : Array(WideTupleField),
        leaf_buffers : Array(TupleLeafBuffers),
        leaf_null_maps : Array(Array(UInt8)?),
        schedule : TupleLeafMarkSchedule,
        infrastructure : TuplePartInfrastructure,
      ) : Array(ChecksumRecord)
        unless fields.size == leaf_buffers.size && fields.size == leaf_null_maps.size
          raise ArgumentError.new("Tuple leaf stream inputs differ from the schema")
        end

        records = [] of ChecksumRecord
        fields.each_with_index do |field, index|
          logical_name = type_plan.leaf_stream_name(value_name, field)
          if null_map = leaf_null_maps[index]
            records.concat(infrastructure.write_numeric_stream(
              stage, "#{logical_name}.null", null_map.as(WideTupleNumericType::Buffer),
              schedule.rows_per_mark, "UInt8", schedule
            ))
          end
          stream_type_name = leaf_null_maps[index] ? nullable_physical_type_name(field) : field.type_name
          case values = leaf_buffers[index]
          when Array(UInt64)
            records.concat(infrastructure.write_uint64_stream(
              stage, logical_name, values.to_unsafe.to_slice(values.size), schedule.rows_per_mark, schedule
            ))
          when Array(String)
            records.concat(infrastructure.write_string_streams(
              stage, logical_name, values.to_unsafe.to_slice(values.size), schedule.rows_per_mark, schedule
            ))
          when Array(Bool)
            records.concat(infrastructure.write_bool_stream(
              stage, logical_name, values.to_unsafe.to_slice(values.size), schedule.rows_per_mark, schedule
            ))
          when Array(UUIDValue), Array(IPv4Value), Array(IPv6Value)
            records.concat(infrastructure.write_identifier_stream(
              stage, logical_name, values.as(WideTupleIdentifierType::Buffer), schedule.rows_per_mark,
              stream_type_name, schedule
            ))
          when Array(DateValue), Array(Date32Value), Array(DateTimeValue),
               Array(DateTime64Value), Array(TimeValue), Array(Time64Value)
            records.concat(infrastructure.write_temporal_stream(
              stage, logical_name, values.as(WideTupleTemporalType::Buffer), schedule.rows_per_mark,
              stream_type_name, schedule
            ))
          when Array(FixedStringValue)
            exact_type = field.leaf_type.parameterized_type.as?(WideTupleFixedStringType) ||
                         raise UnsupportedFormatError.new("Tuple FixedString field has no exact owner")
            records.concat(infrastructure.write_fixed_string_stream(
              stage, logical_name, values.as(WideTupleFixedStringType::Buffer), exact_type,
              schedule.rows_per_mark, schedule
            ))
          when Array(Enum8Value), Array(Enum16Value)
            exact_type = field.leaf_type.parameterized_type.as?(WideTupleEnumType) ||
                         raise UnsupportedFormatError.new("Tuple Enum field has no exact owner")
            records.concat(infrastructure.write_enum_stream(
              stage, logical_name, values.as(WideTupleEnumType::Buffer), exact_type,
              schedule.rows_per_mark, schedule
            ))
          when Array(Decimal32Value), Array(Decimal64Value), Array(Decimal128Value), Array(Decimal256TupleValue)
            exact_type = field.leaf_type.parameterized_type.as?(WideTupleDecimalType) ||
                         raise UnsupportedFormatError.new("Tuple Decimal field has no exact owner")
            records.concat(infrastructure.write_decimal_stream(
              stage, logical_name, values.as(WideTupleDecimalType::Buffer), exact_type,
              schedule.rows_per_mark, schedule
            ))
          else
            records.concat(infrastructure.write_numeric_stream(
              stage, logical_name, values.as(WideTupleNumericType::Buffer), schedule.rows_per_mark,
              stream_type_name, schedule
            ))
          end
        end
        records
      end

      private def self.nullable_physical_type_name(field : WideTupleField) : String
        leaf_type = field.leaf_type
        if enum_type = leaf_type.parameterized_type.as?(WideTupleEnumType)
          enum_type.width == 1 ? "Int8" : "Int16"
        elsif decimal_type = leaf_type.parameterized_type.as?(WideTupleDecimalType)
          case decimal_type.storage_width
          when  4 then "Int32"
          when  8 then "Int64"
          when 16 then "Int128"
          else         "Int256"
          end
        elsif leaf_type.base_type_name == "Bool"
          "UInt8"
        else
          leaf_type.base_type_name
        end
      end
    end
  end
end
