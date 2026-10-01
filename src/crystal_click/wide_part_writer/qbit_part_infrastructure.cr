module CrystalClick
  module WidePartWriter
    # Small adapters for the shared Wide-part frame, checksum, index, metadata,
    # staged-reader and exclusive-publication owners.
    private class QBitPartInfrastructure
      def initialize(
        @stage_factory : Proc(String, String),
        @validate_column_name : Proc(String, Nil),
        @checked_mark_count : Proc(Int32, Int32, Int32),
        @write_uint64_stream : Proc(String, String, Slice(UInt64), Int32, Array(ChecksumRecord)),
        @write_fixed_width_stream : Proc(String, String, Int32, Int32, Int32, Proc(Bytes, Int32, Int32, Nil), Array(ChecksumRecord)),
        @write_primary_index : Proc(String, Slice(UInt64), Int32, ChecksumRecord),
        @write_checksummed_file : Proc(String, String, String, ChecksumRecord),
        @write_plain_metadata : Proc(String, String, String, Nil),
        @write_checksums : Proc(String, Array(ChecksumRecord), ChecksumRecord),
        @validate_checksum_hash : Proc(String, String, {UInt64, UInt64}, Nil),
        @before_validation_hook : Proc(String, QBitPartWriteInput, Nil),
        @publish_exclusively : Proc(String, String, Nil),
        @checked_frame_size : Proc(Int64, String, Int64),
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

      def write_fixed_width_stream(
        stage : String,
        column : String,
        row_count : Int32,
        width : Int32,
        rows_per_mark : Int32,
        &encode_row : Bytes, Int32, Int32 -> Nil
      ) : Array(ChecksumRecord)
        @write_fixed_width_stream.call(stage, column, row_count, width, rows_per_mark, ->(raw : Bytes, source_row : Int32, output_row : Int32) {
          encode_row.call(raw, source_row, output_row)
        })
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

      def write_checksums(stage : String, records : Array(ChecksumRecord)) : ChecksumRecord
        @write_checksums.call(stage, records)
      end

      def validate_checksum_hash(stage : String, name : String, expected_hash : {UInt64, UInt64}) : Nil
        @validate_checksum_hash.call(stage, name, expected_hash)
      end

      # Spec seam for injecting a staged defect before the mandatory validator.
      # Production facades supply a no-op; this callback cannot replace validation.
      def before_validation_hook(stage : String, input : QBitPartWriteInput) : Nil
        @before_validation_hook.call(stage, input)
      end

      def publish_exclusively(stage : String, target : String) : Nil
        @publish_exclusively.call(stage, target)
      end

      def checked_frame_size(raw_size : Int64, label : String) : Int64
        @checked_frame_size.call(raw_size, label)
      end
    end
  end
end
