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
          records.concat(write_leaf(
            stage, logical_name, field.leaf_type, leaf_buffers[index], leaf_null_maps[index],
            schedule, infrastructure
          ))
        end
        records
      end

      # Emit one exact schema leaf under an explicitly supplied physical name.
      # Tuple and Map writers share this codec route; their containers retain
      # their own schema identity, cardinality and mark orchestration.
      def self.write_leaf(
        stage : String,
        logical_name : String,
        leaf_type : WideTupleLeafType,
        values : TupleLeafBuffers,
        leaf_null_map : Array(UInt8)?,
        schedule : TupleLeafMarkSchedule,
        infrastructure : TuplePartInfrastructure,
      ) : Array(ChecksumRecord)
        unless leaf_type.nullable? == !leaf_null_map.nil?
          raise ArgumentError.new("Tuple leaf null map does not match its descriptor")
        end
        if null_map = leaf_null_map
          raise ArgumentError.new("Tuple leaf null map cardinality differs") unless null_map.size == values.size
          yield_records = infrastructure.write_numeric_stream(
            stage, "#{logical_name}.null", null_map.as(WideTupleNumericType::Buffer),
            schedule.rows_per_mark, "UInt8", schedule
          )
        else
          yield_records = [] of ChecksumRecord
        end

        stream_type_name = leaf_type.nullable? ? nullable_physical_type_name(leaf_type) : leaf_type.type_name
        case values
        when Array(UInt64)
          yield_records.concat(infrastructure.write_uint64_stream(
            stage, logical_name, values.to_unsafe.to_slice(values.size), schedule.rows_per_mark, schedule
          ))
        when Array(String)
          yield_records.concat(infrastructure.write_string_streams(
            stage, logical_name, values.to_unsafe.to_slice(values.size), schedule.rows_per_mark, schedule
          ))
        when Array(Bool)
          yield_records.concat(infrastructure.write_bool_stream(
            stage, logical_name, values.to_unsafe.to_slice(values.size), schedule.rows_per_mark, schedule
          ))
        when Array(UUIDValue), Array(IPv4Value), Array(IPv6Value)
          yield_records.concat(infrastructure.write_identifier_stream(
            stage, logical_name, values.as(WideTupleIdentifierType::Buffer), schedule.rows_per_mark,
            stream_type_name, schedule
          ))
        when Array(DateValue), Array(Date32Value), Array(DateTimeValue),
             Array(DateTime64Value), Array(TimeValue), Array(Time64Value)
          yield_records.concat(infrastructure.write_temporal_stream(
            stage, logical_name, values.as(WideTupleTemporalType::Buffer), schedule.rows_per_mark,
            stream_type_name, schedule
          ))
        when Array(FixedStringValue)
          exact_type = leaf_type.parameterized_type.as?(WideTupleFixedStringType) ||
                       raise UnsupportedFormatError.new("Tuple FixedString field has no exact owner")
          yield_records.concat(infrastructure.write_fixed_string_stream(
            stage, logical_name, values.as(WideTupleFixedStringType::Buffer), exact_type,
            schedule.rows_per_mark, schedule
          ))
        when Array(Enum8Value), Array(Enum16Value)
          exact_type = leaf_type.parameterized_type.as?(WideTupleEnumType) ||
                       raise UnsupportedFormatError.new("Tuple Enum field has no exact owner")
          yield_records.concat(infrastructure.write_enum_stream(
            stage, logical_name, values.as(WideTupleEnumType::Buffer), exact_type,
            schedule.rows_per_mark, schedule
          ))
        when Array(Decimal32Value), Array(Decimal64Value), Array(Decimal128Value), Array(Decimal256TupleValue)
          exact_type = leaf_type.parameterized_type.as?(WideTupleDecimalType) ||
                       raise UnsupportedFormatError.new("Tuple Decimal field has no exact owner")
          yield_records.concat(infrastructure.write_decimal_stream(
            stage, logical_name, values.as(WideTupleDecimalType::Buffer), exact_type,
            schedule.rows_per_mark, schedule
          ))
        else
          yield_records.concat(infrastructure.write_numeric_stream(
            stage, logical_name, values.as(WideTupleNumericType::Buffer), schedule.rows_per_mark,
            stream_type_name, schedule
          ))
        end
        yield_records
      end

      private def self.nullable_physical_type_name(leaf_type : WideTupleLeafType) : String
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
