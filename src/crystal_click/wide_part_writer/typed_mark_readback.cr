module CrystalClick
  module WidePartWriter
    private class TypedMarkReadback
      private def self.read_simple_aggregate_numeric(
        part : WidePart,
        column : String,
        mark_index : Int,
        type : T.class,
        type_name : String,
      ) : Array(T)? forall T
        aggregate_type = SimpleAggregateColumnType.parse(type_name) || return nil
        unless aggregate_type.shape == SimpleAggregateColumnType::Shape::Scalar
          raise UnsupportedFormatError.new("typed writer requires an exact scalar SimpleAggregateFunction payload")
        end
        part.read_simple_aggregate_numeric_mark_range(column, mark_index, 1, type)
      end

      private def self.read_nullable_simple_aggregate_numeric(
        part : WidePart,
        column : String,
        mark_index : Int,
        type : T.class,
        type_name : String,
      ) : Array(T?)? forall T
        aggregate_type = SimpleAggregateColumnType.parse(type_name) || return nil
        unless aggregate_type.shape == SimpleAggregateColumnType::Shape::Nullable
          raise UnsupportedFormatError.new("typed Nullable writer requires an exact Nullable(SimpleAggregateFunction) payload")
        end
        part.read_nullable_simple_aggregate_numeric_mark_range(column, mark_index, 1, type)
      end

      def self.read_numeric(
        part : WidePart,
        column : String,
        mark_index : Int,
        values : Slice(T),
        type_name : String,
      ) : Array(T) forall T
        {% if T == BFloat16Value %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, BFloat16Value, type_name)
            aggregate_values
          elsif type_name == "BFloat16"
            part.read_bfloat16_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("typed BFloat16 writer requires exact BFloat16 metadata")
          end
        {% elsif T == UUIDValue %}
          if type_name == "UUID"
            part.read_uuids_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("typed UUID writer requires exact UUID metadata")
          end
        {% elsif T == IPv4Value %}
          if type_name == "IPv4"
            part.read_ipv4s_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("typed IPv4 writer requires exact IPv4 metadata")
          end
        {% elsif T == IPv6Value %}
          if type_name == "IPv6"
            part.read_ipv6s_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("typed IPv6 writer requires exact IPv6 metadata")
          end
        {% elsif T == Decimal256Value %}
          if WidePart.decimal256_scale(type_name)
            part.read_decimal256_raw_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("typed Decimal256 writer requires exact Decimal(P, S) metadata in the 39..76 precision band")
          end
        {% elsif T == Bool %}
          part.read_bool_mark_range(column, mark_index, 1)
        {% elsif T == UInt8 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, UInt8, type_name)
            aggregate_values
          else
            part.read_numeric_mark_range(column, mark_index, 1, UInt8)
          end
        {% elsif T == UInt16 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, UInt16, type_name)
            aggregate_values
          elsif type_name == "Date"
            part.read_date_codes_mark_range(column, mark_index, 1)
          elsif type_name == "UInt16"
            part.read_numeric_mark_range(column, mark_index, 1, UInt16)
          else
            raise UnsupportedFormatError.new("typed writer requires an exact UInt16 or Date payload")
          end
        {% elsif T == UInt32 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, UInt32, type_name)
            aggregate_values
          elsif temporal_type = DateTimeColumnType.parse(type_name)
            if temporal_type.family == DateTimeColumnType::Family::DateTime && temporal_type.shape == DateTimeColumnType::Shape::Scalar
              part.read_datetime_seconds_mark_range(column, mark_index, 1)
            else
              raise UnsupportedFormatError.new("typed writer requires an exact UInt32 or DateTime payload")
            end
          elsif type_name == "UInt32"
            part.read_numeric_mark_range(column, mark_index, 1, UInt32)
          else
            raise UnsupportedFormatError.new("typed writer requires an exact UInt32 or DateTime payload")
          end
        {% elsif T == UInt64 %}
          if aggregate_type = SimpleAggregateColumnType.parse(type_name)
            unless aggregate_type.shape == SimpleAggregateColumnType::Shape::Scalar
              raise UnsupportedFormatError.new("typed writer requires an exact scalar SimpleAggregateFunction payload")
            end
            part.read_simple_aggregate_uint64_mark_range(column, mark_index, 1)
          else
            part.read_numeric_mark_range(column, mark_index, 1, UInt64)
          end
        {% elsif T == Int8 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, Int8, type_name)
            aggregate_values
          elsif WidePart.enum8_codes(type_name)
            part.read_enum8_codes_mark_range(column, mark_index, 1)
          elsif type_name == "Int8"
            part.read_numeric_mark_range(column, mark_index, 1, Int8)
          else
            raise UnsupportedFormatError.new("typed writer requires an exact Int8 or Enum8 payload")
          end
        {% elsif T == Int16 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, Int16, type_name)
            aggregate_values
          elsif WidePart.enum16_codes(type_name)
            part.read_enum16_codes_mark_range(column, mark_index, 1)
          elsif type_name == "Int16"
            part.read_numeric_mark_range(column, mark_index, 1, Int16)
          else
            raise UnsupportedFormatError.new("typed writer requires an exact Int16 or Enum16 payload")
          end
        {% elsif T == Int32 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, Int32, type_name)
            aggregate_values
          elsif type_name == "Time"
            part.read_time_seconds_mark_range(column, mark_index, 1)
          elsif type_name == "Date32"
            part.read_date32_codes_mark_range(column, mark_index, 1)
          elsif WidePart.decimal32_scale(type_name)
            part.read_decimal32_raw_mark_range(column, mark_index, 1)
          elsif type_name == "Int32"
            part.read_numeric_mark_range(column, mark_index, 1, Int32)
          else
            raise UnsupportedFormatError.new("typed writer requires an exact Int32 or Date32 payload")
          end
        {% elsif T == Int64 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, Int64, type_name)
            aggregate_values
          elsif WidePart.time64_scale(type_name)
            part.read_time64_ticks_mark_range(column, mark_index, 1)
          elsif interval_type = IntervalColumnType.parse(type_name)
            if interval_type.shape == IntervalColumnType::Shape::Scalar
              part.read_interval_counts_mark_range(column, mark_index, 1)
            else
              raise UnsupportedFormatError.new("typed writer requires an exact Int64, DateTime64, or scalar Interval payload")
            end
          elsif temporal_type = DateTimeColumnType.parse(type_name)
            if temporal_type.family == DateTimeColumnType::Family::DateTime64 && temporal_type.shape == DateTimeColumnType::Shape::Scalar
              part.read_datetime64_ticks_mark_range(column, mark_index, 1)
            else
              raise UnsupportedFormatError.new("typed writer requires an exact Int64 or DateTime64 payload")
            end
          elsif WidePart.decimal64_scale(type_name)
            part.read_decimal64_raw_mark_range(column, mark_index, 1)
          elsif type_name == "Int64"
            part.read_numeric_mark_range(column, mark_index, 1, Int64)
          else
            raise UnsupportedFormatError.new("typed writer requires an exact Int64 or DateTime64 payload")
          end
        {% elsif T == Int128 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, Int128, type_name)
            aggregate_values
          elsif type_name == "Int128"
            part.read_int128_raw_mark_range(column, mark_index, 1)
          elsif WidePart.decimal128_scale(type_name)
            part.read_decimal128_raw_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("Int128 payload requires exact Int128 or Decimal(P, S) metadata in the 19..38 precision band")
          end
        {% elsif T == UInt128 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, UInt128, type_name)
            aggregate_values
          elsif type_name == "UInt128"
            part.read_uint128_raw_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("UInt128 payload requires exact UInt128 metadata")
          end
        {% elsif T == Int256Value %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, Int256Value, type_name)
            aggregate_values
          elsif type_name == "Int256"
            part.read_int256_raw_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("Int256 payload requires exact Int256 metadata")
          end
        {% elsif T == UInt256Value %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, UInt256Value, type_name)
            aggregate_values
          elsif type_name == "UInt256"
            part.read_uint256_raw_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("UInt256 payload requires exact UInt256 metadata")
          end
        {% elsif T == Float32 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, Float32, type_name)
            aggregate_values
          else
            part.read_numeric_mark_range(column, mark_index, 1, Float32)
          end
        {% elsif T == Float64 %}
          if aggregate_values = read_simple_aggregate_numeric(part, column, mark_index, Float64, type_name)
            aggregate_values
          else
            part.read_numeric_mark_range(column, mark_index, 1, Float64)
          end
        {% else %}
          raise UnsupportedFormatError.new("typed writer requires an exact fixed-width primitive numeric payload")
        {% end %}
      end

      def self.read_nullable_numeric(
        part : WidePart,
        column : String,
        mark_index : Int,
        values : Slice(T),
        type_name : String,
      ) : Array(T) forall T
        {% if T == BFloat16Value? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, BFloat16Value, type_name)
            aggregate_values
          elsif type_name == "Nullable(BFloat16)"
            part.read_nullable_bfloat16_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("typed Nullable BFloat16 writer requires exact Nullable(BFloat16) metadata")
          end
        {% elsif T == UUIDValue? %}
          if type_name == "Nullable(UUID)"
            part.read_nullable_uuids_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("typed Nullable UUID writer requires exact Nullable(UUID) metadata")
          end
        {% elsif T == IPv4Value? %}
          if type_name == "Nullable(IPv4)"
            part.read_nullable_ipv4s_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("typed Nullable IPv4 writer requires exact Nullable(IPv4) metadata")
          end
        {% elsif T == IPv6Value? %}
          if type_name == "Nullable(IPv6)"
            part.read_nullable_ipv6s_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("typed Nullable IPv6 writer requires exact Nullable(IPv6) metadata")
          end
        {% elsif T == Decimal256Value? %}
          if WidePart.nullable_decimal256_scale(type_name)
            part.read_nullable_decimal256_raw_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("typed Nullable Decimal256 writer requires exact Nullable(Decimal(P, S)) metadata in the 39..76 precision band")
          end
        {% elsif T == Bool? %}
          part.read_nullable_bool_mark_range(column, mark_index, 1)
        {% elsif T == UInt8? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, UInt8, type_name)
            aggregate_values
          else
            part.read_nullable_numeric_mark_range(column, mark_index, 1, UInt8)
          end
        {% elsif T == UInt16? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, UInt16, type_name)
            aggregate_values
          elsif type_name == "Nullable(Date)"
            part.read_nullable_date_codes_mark_range(column, mark_index, 1)
          elsif type_name == "Nullable(UInt16)"
            part.read_nullable_numeric_mark_range(column, mark_index, 1, UInt16)
          else
            raise UnsupportedFormatError.new("typed Nullable UInt16 writer requires exact Date or numeric metadata")
          end
        {% elsif T == UInt32? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, UInt32, type_name)
            aggregate_values
          elsif temporal_type = DateTimeColumnType.parse(type_name)
            if temporal_type.family == DateTimeColumnType::Family::DateTime && temporal_type.shape == DateTimeColumnType::Shape::Nullable
              part.read_nullable_datetime_seconds_mark_range(column, mark_index, 1)
            else
              raise UnsupportedFormatError.new("typed Nullable UInt32 writer requires exact DateTime or numeric metadata")
            end
          elsif type_name == "Nullable(UInt32)"
            part.read_nullable_numeric_mark_range(column, mark_index, 1, UInt32)
          else
            raise UnsupportedFormatError.new("typed Nullable UInt32 writer requires exact DateTime or numeric metadata")
          end
        {% elsif T == UInt64? %}
          if aggregate_type = SimpleAggregateColumnType.parse(type_name)
            unless aggregate_type.shape == SimpleAggregateColumnType::Shape::Nullable
              raise UnsupportedFormatError.new("typed Nullable writer requires an exact Nullable(SimpleAggregateFunction) payload")
            end
            part.read_nullable_simple_aggregate_uint64_mark_range(column, mark_index, 1)
          else
            part.read_nullable_numeric_mark_range(column, mark_index, 1, UInt64)
          end
        {% elsif T == Int8? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, Int8, type_name)
            aggregate_values
          elsif WidePart.enum8_codes(type_name)
            part.read_nullable_enum8_codes_mark_range(column, mark_index, 1)
          elsif type_name == "Nullable(Int8)"
            part.read_nullable_numeric_mark_range(column, mark_index, 1, Int8)
          else
            raise UnsupportedFormatError.new("typed Nullable Int8 writer requires exact Enum8 or numeric metadata")
          end
        {% elsif T == Int16? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, Int16, type_name)
            aggregate_values
          elsif WidePart.enum16_codes(type_name)
            part.read_nullable_enum16_codes_mark_range(column, mark_index, 1)
          elsif type_name == "Nullable(Int16)"
            part.read_nullable_numeric_mark_range(column, mark_index, 1, Int16)
          else
            raise UnsupportedFormatError.new("typed Nullable Int16 writer requires exact Enum16 or numeric metadata")
          end
        {% elsif T == Int32? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, Int32, type_name)
            aggregate_values
          elsif type_name == "Nullable(Time)"
            part.read_nullable_time_seconds_mark_range(column, mark_index, 1)
          elsif type_name == "Nullable(Date32)"
            part.read_nullable_date32_codes_mark_range(column, mark_index, 1)
          elsif WidePart.nullable_decimal32_scale(type_name)
            part.read_nullable_decimal32_raw_mark_range(column, mark_index, 1)
          elsif type_name == "Nullable(Int32)"
            part.read_nullable_numeric_mark_range(column, mark_index, 1, Int32)
          else
            raise UnsupportedFormatError.new("typed Nullable Int32 writer requires exact Date32 or numeric metadata")
          end
        {% elsif T == Int64? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, Int64, type_name)
            aggregate_values
          elsif WidePart.nullable_time64_scale(type_name)
            part.read_nullable_time64_ticks_mark_range(column, mark_index, 1)
          elsif interval_type = IntervalColumnType.parse(type_name)
            if interval_type.shape == IntervalColumnType::Shape::Nullable
              part.read_nullable_interval_counts_mark_range(column, mark_index, 1)
            else
              raise UnsupportedFormatError.new("typed Nullable Int64 writer requires exact Nullable(Interval) metadata")
            end
          elsif temporal_type = DateTimeColumnType.parse(type_name)
            if temporal_type.family == DateTimeColumnType::Family::DateTime64 && temporal_type.shape == DateTimeColumnType::Shape::Nullable
              part.read_nullable_datetime64_ticks_mark_range(column, mark_index, 1)
            else
              raise UnsupportedFormatError.new("typed Nullable Int64 writer requires exact DateTime64 or numeric metadata")
            end
          elsif WidePart.nullable_decimal64_scale(type_name)
            part.read_nullable_decimal64_raw_mark_range(column, mark_index, 1)
          elsif type_name == "Nullable(Int64)"
            part.read_nullable_numeric_mark_range(column, mark_index, 1, Int64)
          else
            raise UnsupportedFormatError.new("typed Nullable Int64 writer requires exact DateTime64 or numeric metadata")
          end
        {% elsif T == Int128? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, Int128, type_name)
            aggregate_values
          elsif type_name == "Nullable(Int128)"
            part.read_nullable_int128_raw_mark_range(column, mark_index, 1)
          elsif WidePart.nullable_decimal128_scale(type_name)
            part.read_nullable_decimal128_raw_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("Nullable Int128 payload requires exact Nullable(Int128) or Nullable(Decimal(P, S)) metadata in the 19..38 precision band")
          end
        {% elsif T == UInt128? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, UInt128, type_name)
            aggregate_values
          elsif type_name == "Nullable(UInt128)"
            part.read_nullable_uint128_raw_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("Nullable UInt128 payload requires exact Nullable(UInt128) metadata")
          end
        {% elsif T == Int256Value? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, Int256Value, type_name)
            aggregate_values
          elsif type_name == "Nullable(Int256)"
            part.read_nullable_int256_raw_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("Nullable Int256 payload requires exact Nullable(Int256) metadata")
          end
        {% elsif T == UInt256Value? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, UInt256Value, type_name)
            aggregate_values
          elsif type_name == "Nullable(UInt256)"
            part.read_nullable_uint256_raw_mark_range(column, mark_index, 1)
          else
            raise UnsupportedFormatError.new("Nullable UInt256 payload requires exact Nullable(UInt256) metadata")
          end
        {% elsif T == Float32? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, Float32, type_name)
            aggregate_values
          else
            part.read_nullable_numeric_mark_range(column, mark_index, 1, Float32)
          end
        {% elsif T == Float64? %}
          if aggregate_values = read_nullable_simple_aggregate_numeric(part, column, mark_index, Float64, type_name)
            aggregate_values
          else
            part.read_nullable_numeric_mark_range(column, mark_index, 1, Float64)
          end
        {% else %}
          raise UnsupportedFormatError.new("unsupported typed Nullable numeric payload")
        {% end %}
      end
    end
  end
end
