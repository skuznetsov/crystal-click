module CrystalClick
  module WidePartWriter
    # Narrow adapters to the writer's existing private stage, leaf, checksum,
    # index, metadata and publication helpers. TuplePartWriter owns the new
    # schema and stage orchestration; it does not copy those shared codecs.
    private class TuplePartInfrastructure
      def initialize(
        @stage_factory : Proc(String, String),
        @validate_column_name : Proc(String, Nil),
        @checked_mark_count : Proc(Int32, Int32, Int32),
        @write_uint64_stream : Proc(String, String, Slice(UInt64), Int32, Array(ChecksumRecord)),
        @write_string_streams : Proc(String, String, Slice(String), Int32, Array(ChecksumRecord)),
        @write_bool_stream : Proc(String, String, Slice(Bool), Int32, Array(ChecksumRecord)),
        @validate_bool_stream : Proc(String, String, Array(Bool), Int32, Nil),
        @write_numeric_stream : Proc(String, String, WideTupleNumericType::Buffer, Int32, String, Array(ChecksumRecord)),
        @write_identifier_stream : Proc(String, String, WideTupleIdentifierType::Buffer, Int32, String, Array(ChecksumRecord)),
        @write_temporal_stream : Proc(String, String, WideTupleTemporalType::Buffer, Int32, String, Array(ChecksumRecord)),
        @write_fixed_string_stream : Proc(String, String, WideTupleFixedStringType::Buffer, WideTupleFixedStringType, Int32, Array(ChecksumRecord)),
        @write_enum_stream : Proc(String, String, WideTupleEnumType::Buffer, WideTupleEnumType, Int32, Array(ChecksumRecord)),
        @write_decimal_stream : Proc(String, String, WideTupleDecimalType::Buffer, WideTupleDecimalType, Int32, Array(ChecksumRecord)),
        @write_primary_index : Proc(String, Slice(UInt64), Int32, ChecksumRecord),
        @write_checksummed_file : Proc(String, String, String, ChecksumRecord),
        @write_plain_metadata : Proc(String, String, String, Nil),
        @write_checksums : Proc(String, Array(ChecksumRecord), Nil),
        @publish_exclusively : Proc(String, String, Nil),
        @checked_string_frame_size : Proc(Int64, String, Int64),
        @copy_string_values : Proc(WideTupleLeafColumn, Array(String)),
      )
      end

      def stage_factory : Proc(String, String)
        @stage_factory
      end

      def validate_column_name(name : String) : Nil
        @validate_column_name.call(name)
      end

      def checked_mark_count(row_count : Int32, rows_per_mark : Int32) : Int32
        @checked_mark_count.call(row_count, rows_per_mark)
      end

      def write_uint64_stream(stage : String, column : String, values : Slice(UInt64), rows_per_mark : Int32) : Array(ChecksumRecord)
        @write_uint64_stream.call(stage, column, values, rows_per_mark)
      end

      def write_string_streams(stage : String, column : String, values : Slice(String), rows_per_mark : Int32) : Array(ChecksumRecord)
        @write_string_streams.call(stage, column, values, rows_per_mark)
      end

      def write_bool_stream(stage : String, column : String, values : Slice(Bool), rows_per_mark : Int32) : Array(ChecksumRecord)
        @write_bool_stream.call(stage, column, values, rows_per_mark)
      end

      def validate_bool_stream(stage : String, column : String, values : Array(Bool), rows_per_mark : Int32) : Nil
        @validate_bool_stream.call(stage, column, values, rows_per_mark)
      end

      def write_numeric_stream(
        stage : String,
        column : String,
        values : WideTupleNumericType::Buffer,
        rows_per_mark : Int32,
        type_name : String,
      ) : Array(ChecksumRecord)
        @write_numeric_stream.call(stage, column, values, rows_per_mark, type_name)
      end

      def write_identifier_stream(
        stage : String,
        column : String,
        values : WideTupleIdentifierType::Buffer,
        rows_per_mark : Int32,
        type_name : String,
      ) : Array(ChecksumRecord)
        @write_identifier_stream.call(stage, column, values, rows_per_mark, type_name)
      end

      def write_temporal_stream(
        stage : String,
        column : String,
        values : WideTupleTemporalType::Buffer,
        rows_per_mark : Int32,
        type_name : String,
      ) : Array(ChecksumRecord)
        @write_temporal_stream.call(stage, column, values, rows_per_mark, type_name)
      end

      def write_fixed_string_stream(
        stage : String,
        column : String,
        values : WideTupleFixedStringType::Buffer,
        exact_type : WideTupleFixedStringType,
        rows_per_mark : Int32,
      ) : Array(ChecksumRecord)
        @write_fixed_string_stream.call(stage, column, values, exact_type, rows_per_mark)
      end

      def write_enum_stream(
        stage : String,
        column : String,
        values : WideTupleEnumType::Buffer,
        exact_type : WideTupleEnumType,
        rows_per_mark : Int32,
      ) : Array(ChecksumRecord)
        @write_enum_stream.call(stage, column, values, exact_type, rows_per_mark)
      end

      def write_decimal_stream(
        stage : String,
        column : String,
        values : WideTupleDecimalType::Buffer,
        exact_type : WideTupleDecimalType,
        rows_per_mark : Int32,
      ) : Array(ChecksumRecord)
        @write_decimal_stream.call(stage, column, values, exact_type, rows_per_mark)
      end

      def write_primary_index(stage : String, keys : Slice(UInt64), rows_per_mark : Int32) : ChecksumRecord
        @write_primary_index.call(stage, keys, rows_per_mark)
      end

      def write_checksummed_file(stage : String, name : String, content : String) : ChecksumRecord
        @write_checksummed_file.call(stage, name, content)
      end

      def write_plain_metadata(stage : String, name : String, content : String) : Nil
        @write_plain_metadata.call(stage, name, content)
      end

      def write_checksums(stage : String, records : Array(ChecksumRecord)) : Nil
        @write_checksums.call(stage, records)
      end

      def publish_exclusively(stage : String, target : String) : Nil
        @publish_exclusively.call(stage, target)
      end

      def checked_string_frame_size(raw_size : Int64, label : String) : Int64
        @checked_string_frame_size.call(raw_size, label)
      end

      def copy_string_values(column : WideTupleLeafColumn) : Array(String)
        @copy_string_values.call(column)
      end
    end
  end
end
